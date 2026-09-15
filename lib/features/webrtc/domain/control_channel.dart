/// The label the two ends agree on for the one data channel this system uses.
///
/// `remote_control_web` creates it; `remote_control_device` receives it. It is
/// the whole of the contract between them at this stage: a channel with this
/// label is the control channel, and a channel with any other label is not
/// something this build knows about and is closed.
///
/// Nothing travels over it yet. The commands it will eventually carry — tap,
/// swipe, Back, Home, text — need an Android `AccessibilityService` that does
/// not exist in this build, and inventing a wire format before there is
/// anything to execute would mean designing it twice.
const String controlDataChannelLabel = 'control';
