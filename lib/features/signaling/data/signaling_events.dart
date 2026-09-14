/// Event names and size limits transcribed from `docs/backend/REALTIME.md`.
///
/// They live together because they are one thing: the shape of the wire. A
/// limit that drifts from the document is as much a contract break as a
/// misspelled event name, and a single file is what makes both checkable
/// against the copy of the contract in one reading.
library;

/// Sent by the device to enter a remote session's signaling room. Mandatory
/// before any `webrtc:*`, and to be resent after every reconnection — a fresh
/// socket carries no joined session.
const String remoteSessionJoinEvent = 'remote-session:join';

/// Bidirectional. Either end may create the offer; the backend is
/// direction-neutral and never parses the SDP.
const String webRtcOfferEvent = 'webrtc:offer';

/// Bidirectional. Identical to [webRtcOfferEvent] in payload, constraints and
/// ACK — the offer/answer distinction lives entirely in the event name.
const String webRtcAnswerEvent = 'webrtc:answer';

/// Bidirectional.
const String webRtcIceCandidateEvent = 'webrtc:ice-candidate';

/// `sdp`: 1–32768 characters. An empty SDP is *not* valid.
const int minSdpLength = 1;
const int maxSdpLength = 32768;

/// `candidate`: max 1024 characters. The empty string **is** valid — some
/// implementations use it to signal end-of-candidates.
const int maxIceCandidateLength = 1024;

/// `sdpMid`: max 64 characters when present.
const int maxSdpMidLength = 64;

/// `sdpMLineIndex`: `0-255` when present.
const int minSdpMLineIndex = 0;
const int maxSdpMLineIndex = 255;
