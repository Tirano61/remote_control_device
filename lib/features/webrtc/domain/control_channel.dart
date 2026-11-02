/// The label the two ends agree on for the one data channel this system uses.
///
/// `remote_control_web` creates it; `remote_control_device` receives it. A
/// channel with this label is the control channel, and a channel with any other
/// label is not something this build knows about and is closed.
///
/// What travels over it is defined in `docs/webrtc/CONTROL_CHANNEL.md`.
const String controlDataChannelLabel = 'control';
