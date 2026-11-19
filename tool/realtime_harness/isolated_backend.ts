/*
 * Isolated backend for the /devices reconnection tests (Prompts 34–36).
 * See tool/realtime_harness/README.md for how to run it.
 *
 * Real remote_control_backend code (DevicesGateway + its namespace middleware,
 * DeviceAuthController/Service, DeviceJwtStrategy, DevicesService, presence),
 * TypeORM repositories replaced by in-memory doubles with fault injection.
 * No PostgreSQL, no Neon, no shared backend. Fictitious device and secret.
 *
 *   127.0.0.1:3100  TCP relay (what the Dart client talks to; can be cut)
 *   127.0.0.1:3101  Nest app (HTTP + Socket.IO)
 *   127.0.0.1:3102  control API (POST /ctl, GET /log, POST /reset)
 */
import { ValidationPipe, INestApplication, Logger, UnauthorizedException } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { JwtModule, JwtService } from '@nestjs/jwt';
import { PassportModule } from '@nestjs/passport';
import { Test } from '@nestjs/testing';
import { getRepositoryToken } from '@nestjs/typeorm';
import { createHash } from 'crypto';
import * as http from 'http';
import * as net from 'net';
import * as path from 'path';

// The sibling checkout of remote_control_backend; override with BACKEND_SRC.
const B =
  process.env.BACKEND_SRC ??
  path.resolve(__dirname, '../../../remote_control_backend/src');
/* eslint-disable @typescript-eslint/no-require-imports */
const { DeviceAuthController } = require(`${B}/devices/auth/device-auth.controller`);
const { DeviceAuthService } = require(`${B}/devices/auth/device-auth.service`);
const { DeviceCredentialsService } = require(`${B}/devices/auth/device-credentials.service`);
const { DeviceJwtStrategy } = require(`${B}/devices/auth/strategies/device-jwt.strategy`);
const { DevicesService } = require(`${B}/devices/devices.service`);
const { DevicePresenceService } = require(`${B}/devices/presence/device-presence.service`);
const { DeviceRealtimeService } = require(`${B}/devices/realtime/device-realtime.service`);
const { DevicesGateway } = require(`${B}/devices/gateway/devices.gateway`);
const { classifyHandshakeFailure } = require(`${B}/devices/gateway/device-handshake-error`);
const { SignalingService } = require(`${B}/signaling/signaling.service`);
const { SessionParticipationService } = require(`${B}/signaling/participation/session-participation.service`);
const { SignalingRealtimeService } = require(`${B}/signaling/realtime/signaling-realtime.service`);
const { TechnicianRealtimeService } = require(`${B}/signaling/realtime/technician-realtime.service`);
const { Device } = require(`${B}/devices/entities/device.entity`);
const { DeviceCredential } = require(`${B}/devices/entities/device-credential.entity`);
const { RemoteSession } = require(`${B}/remote-sessions/entities/remote-session.entity`);
const { SocketIoAdapter } = require(`${B}/config/socket-io.adapter`);

const RELAY_PORT = 3100;
const APP_PORT = 3101;
const CTL_PORT = 3102;

// Fictitious identity. Not a real device, not a real secret.
export const DEVICE_ID = '11111111-2222-4333-8444-555555555555';
export const PUBLIC_ID = '999-000-034';
export const DEVICE_SECRET = 'p34-fictitious-secret-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const CREDENTIAL_ID = '66666666-7777-4888-8999-000000000000';

const sha256 = (v: string) => createHash('sha256').update(v, 'utf8').digest('hex');

/** A pg-like infrastructure failure, the kind TypeORM surfaces. */
class SimulatedDbError extends Error {
  constructor() {
    super('Connection terminated due to connection timeout');
    this.name = 'QueryFailedError';
  }
}

interface Faults {
  rejectHandshakes: number; // next N handshakes refused by the auth step (UnauthorizedException -> DEVICE_AUTH_UNAUTHORIZED)
  dbFailHandshakes: number; // next N handshakes hit a DB error inside authorizePayload (-> DEVICE_AUTH_UNAVAILABLE)
  dbDown: boolean; // every repository call fails (login -> 500, handshake -> DEVICE_AUTH_UNAVAILABLE)
  tokenTtlSeconds: number | null; // expiry of the next issued tokens
  cutUntil: number; // relay refuses / drops connections until this epoch ms
}

const freshFaults = (): Faults => ({
  rejectHandshakes: 0,
  dbFailHandshakes: 0,
  dbDown: false,
  tokenTtlSeconds: null,
  cutUntil: 0,
});

let faults = freshFaults();
let device: Record<string, unknown>;
let events: Array<Record<string, unknown>> = [];
const tokenIndex = new Map<string, number>();
let issued = 0;
let handshakeFaultScope = false;

const t0 = Date.now();
const log = (e: Record<string, unknown>) => {
  const entry = { t: Date.now() - t0, ...e };
  events.push(entry);
  console.log(JSON.stringify(entry));
};
/** Tokens are fictitious, but even so only their issue number is recorded. */
const tokenLabel = (token: unknown): string => {
  if (typeof token !== 'string' || token.length === 0) return 'none';
  const n = tokenIndex.get(token);
  return n ? `tok#${n}` : `unknown:${sha256(token).slice(0, 8)}`;
};

const resetState = () => {
  faults = freshFaults();
  events = [];
  tokenIndex.clear();
  issued = 0;
  device = {
    id: DEVICE_ID,
    publicId: PUBLIC_ID,
    name: 'Isolated P34',
    manufacturer: null,
    model: null,
    androidVersion: null,
    appVersion: null,
    isActive: true,
    createdAt: new Date(),
    updatedAt: new Date(),
  };
};
resetState();

const dbCheck = () => {
  if (faults.dbDown || handshakeFaultScope) throw new SimulatedDbError();
};

const deviceRepository = {
  findOneBy: async ({ id }: { id: string }) => {
    dbCheck();
    return id === device.id ? { ...device } : null;
  },
  find: async () => {
    dbCheck();
    return [{ ...device }];
  },
  preload: async ({ id, ...changes }: { id: string }) => {
    dbCheck();
    return id === device.id ? { ...device, ...changes } : undefined;
  },
  save: async (updated: Record<string, unknown>) => {
    dbCheck();
    device = { ...device, ...updated };
    return { ...device };
  },
};

const deviceCredentialRepository = {
  findOne: async ({ where }: { where: { deviceId: string } }) => {
    dbCheck();
    return where.deviceId === device.id
      ? { id: CREDENTIAL_ID, deviceId: device.id, secretHash: sha256(DEVICE_SECRET), revokedAt: null }
      : null;
  },
  update: async () => {
    dbCheck();
    return { affected: 1 };
  },
};

const config: Record<string, string> = {
  DEVICE_JWT_SECRET: 'p34-isolated-device-jwt-secret',
  JWT_SECRET_KEY: 'p34-isolated-user-jwt-secret',
};

async function main() {
  const moduleRef = await Test.createTestingModule({
    imports: [
      PassportModule,
      JwtModule.register({ secret: config.DEVICE_JWT_SECRET, signOptions: { expiresIn: '1h' } }),
    ],
    controllers: [DeviceAuthController],
    providers: [
      DeviceAuthService,
      DeviceCredentialsService,
      DeviceJwtStrategy,
      DevicesGateway,
      DevicePresenceService,
      DeviceRealtimeService,
      DevicesService,
      SignalingService,
      SessionParticipationService,
      SignalingRealtimeService,
      TechnicianRealtimeService,
      { provide: ConfigService, useValue: { get: (k: string) => config[k] } },
      { provide: getRepositoryToken(RemoteSession), useValue: { findOne: async () => null } },
      { provide: getRepositoryToken(Device), useValue: deviceRepository },
      { provide: getRepositoryToken(DeviceCredential), useValue: deviceCredentialRepository },
    ],
  }).compile();

  const app: INestApplication = moduleRef.createNestApplication({ logger: ['error', 'warn', 'log'] });
  app.useWebSocketAdapter(new SocketIoAdapter(app, []));
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: true }));

  // --- observation hooks (wrapping, not replacing, the production paths) ---
  const jwt = app.get(JwtService);
  const origSign = jwt.sign.bind(jwt);
  (jwt as any).sign = (payload: any, opts?: any) => {
    const o = faults.tokenTtlSeconds ? { ...(opts ?? {}), expiresIn: faults.tokenTtlSeconds } : opts;
    const token = origSign(payload, o);
    tokenIndex.set(token, ++issued);
    return token;
  };

  const auth = app.get(DeviceAuthService);
  const origLogin = auth.login.bind(auth);
  auth.login = async (dto: any) => {
    try {
      const r = await origLogin(dto);
      log({ ev: 'login', result: 200, issued: tokenLabel(r.token) });
      return r;
    } catch (e: any) {
      const status = typeof e?.getStatus === 'function' ? e.getStatus() : 500;
      const code = typeof e?.getResponse === 'function' ? (e.getResponse() as any)?.code : undefined;
      log({ ev: 'login', result: status, code: code ?? null });
      throw e;
    }
  };

  // The gateway middleware calls deviceAuthService.authenticateToken(token).
  const origAuthToken = auth.authenticateToken.bind(auth);
  auth.authenticateToken = async (token: string) => {
    const label = tokenLabel(token);
    if (faults.rejectHandshakes > 0) {
      faults.rejectHandshakes--;
      // An authentic refusal, the way DeviceAuthService raises one, so the
      // gateway answers DEVICE_AUTH_UNAUTHORIZED. Anything else would be
      // classified DEVICE_AUTH_UNAVAILABLE by the backend (Prompt 33).
      const refusal = new UnauthorizedException();
      log({ ev: 'handshake', token: label, result: 'rejected (injected)', code: classifyHandshakeFailure(refusal).code });
      throw refusal;
    }
    const dbFail = faults.dbFailHandshakes > 0;
    if (dbFail) faults.dbFailHandshakes--;
    handshakeFaultScope = dbFail;
    try {
      const r = await origAuthToken(token);
      log({ ev: 'handshake', token: label, result: 'accepted' });
      return r;
    } catch (e: any) {
      // `code` is what the gateway's own classifier turns this into, i.e. the
      // data.code of the connect_error the client receives.
      log({
        ev: 'handshake',
        token: label,
        result: `rejected (${e?.name ?? 'Error'}: ${e?.message})`,
        code: classifyHandshakeFailure(e).code,
      });
      throw e;
    } finally {
      handshakeFaultScope = false;
    }
  };

  const presence = app.get(DevicePresenceService);
  const origRegister = presence.register.bind(presence);
  presence.register = (id: string, socket: any) => {
    origRegister(id, socket);
    log({ ev: 'online', sockets: presence.connectionCount(id) });
    socket.on('disconnect', (reason: string) =>
      log({ ev: 'socket-closed', reason, online: presence.isOnline(id) }),
    );
  };

  // Count every HTTP request (protected routes included) without its headers.
  const httpAdapter = app.getHttpAdapter().getInstance();
  httpAdapter.use((req: any, _res: any, next: any) => {
    log({ ev: 'http', method: req.method, path: req.url, auth: tokenLabel((req.headers.authorization ?? '').replace(/^Bearer /, '')) });
    next();
  });

  await app.listen(APP_PORT, '127.0.0.1');
  const devicesService = app.get(DevicesService);

  // --- TCP relay that can be cut ---
  const live = new Set<net.Socket>();
  net
    .createServer((client) => {
      if (Date.now() < faults.cutUntil) {
        client.destroy();
        return;
      }
      const upstream = net.connect(APP_PORT, '127.0.0.1');
      live.add(client);
      live.add(upstream);
      client.pipe(upstream).pipe(client);
      const end = () => {
        live.delete(client);
        live.delete(upstream);
        client.destroy();
        upstream.destroy();
      };
      client.on('error', end).on('close', end);
      upstream.on('error', end).on('close', end);
    })
    .listen(RELAY_PORT, '127.0.0.1');

  // --- control API ---
  http
    .createServer((req, res) => {
      let body = '';
      req.on('data', (c) => (body += c));
      req.on('end', async () => {
        const reply = (code: number, obj: unknown) => {
          res.writeHead(code, { 'content-type': 'application/json' });
          res.end(JSON.stringify(obj));
        };
        try {
          const cmd = body ? JSON.parse(body) : {};
          if (req.url === '/log') return reply(200, { events, online: presence.isOnline(DEVICE_ID), sockets: presence.connectionCount(DEVICE_ID) });
          if (req.url === '/reset') {
            presence.disconnectDevice(DEVICE_ID);
            for (const s of live) s.destroy();
            resetState();
            return reply(200, { ok: true });
          }
          if (req.url === '/ctl') {
            if (typeof cmd.rejectHandshakes === 'number') faults.rejectHandshakes = cmd.rejectHandshakes;
            if (typeof cmd.dbFailHandshakes === 'number') faults.dbFailHandshakes = cmd.dbFailHandshakes;
            if (typeof cmd.dbDown === 'boolean') faults.dbDown = cmd.dbDown;
            if ('tokenTtlSeconds' in cmd) faults.tokenTtlSeconds = cmd.tokenTtlSeconds;
            if (typeof cmd.cutMs === 'number') {
              faults.cutUntil = Date.now() + cmd.cutMs;
              for (const s of live) s.destroy();
              log({ ev: 'relay-cut', ms: cmd.cutMs });
            }
            if (typeof cmd.setActive === 'boolean') {
              // The real admin path: PATCH /devices/:id -> DevicesService.update.
              await devicesService.update(DEVICE_ID, { isActive: cmd.setActive });
              log({ ev: 'admin-update', isActive: cmd.setActive });
            }
            if (cmd.serverDisconnect) {
              const n = presence.disconnectDevice(DEVICE_ID);
              log({ ev: 'server-disconnect', sockets: n });
            }
            log({ ev: 'ctl', ...cmd });
            return reply(200, { ok: true, faults });
          }
          reply(404, {});
        } catch (e: any) {
          reply(500, { error: String(e?.message ?? e) });
        }
      });
    })
    .listen(CTL_PORT, '127.0.0.1');

  Logger.log(`isolated backend up: relay ${RELAY_PORT}, app ${APP_PORT}, ctl ${CTL_PORT}`, 'P34');
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
