/// Thin bridging layer between Zig and the C X11/Xft/Xinerama/fontconfig libraries.
///
/// All C headers are imported once via @cImport in the `c` namespace, and the most
/// commonly used types and constants are re-exported as top-level Zig identifiers so
/// that the rest of the codebase can write `x11.Window` instead of `x11.c.Window`.
/// This keeps C-isms contained to one file and makes imports more readable.
pub const c = @cImport({
    // POSIX / libc
    @cInclude("locale.h");
    @cInclude("signal.h");
    @cInclude("unistd.h");
    @cInclude("sys/wait.h");
    // Core Xlib
    @cInclude("X11/Xlib.h");
    @cInclude("X11/Xatom.h");
    @cInclude("X11/Xutil.h");
    @cInclude("X11/Xproto.h");
    @cInclude("X11/cursorfont.h");
    @cInclude("X11/keysym.h");
    @cInclude("X11/XKBlib.h");
    // Xft font rendering
    @cInclude("X11/Xft/Xft.h");
    // Multi-monitor support
    @cInclude("X11/extensions/Xinerama.h");
    // Font matching / fallback
    @cInclude("fontconfig/fontconfig.h");
});

// ── Core Xlib types ─────────────────────────────────────────────────────────
pub const Display = c.Display;
pub const Window = c.Window;
pub const Drawable = c.Drawable;
pub const GC = c.GC;
pub const Pixmap = c.Pixmap;
pub const Cursor = c.Cursor;
pub const Atom = c.Atom;
pub const KeySym = c.KeySym;
pub const KeyCode = c.KeyCode;
pub const Time = c.Time;

// ── X event types ───────────────────────────────────────────────────────────
pub const XEvent = c.XEvent;
pub const XButtonEvent = c.XButtonPressedEvent;
pub const XKeyEvent = c.XKeyEvent;
pub const XMotionEvent = c.XMotionEvent;
pub const XCrossingEvent = c.XCrossingEvent;
pub const XExposeEvent = c.XExposeEvent;
pub const XFocusChangeEvent = c.XFocusChangeEvent;
pub const XMappingEvent = c.XMappingEvent;
pub const XPropertyEvent = c.XPropertyEvent;
pub const XConfigureEvent = c.XConfigureEvent;
pub const XConfigureRequestEvent = c.XConfigureRequestEvent;
pub const XClientMessageEvent = c.XClientMessageEvent;
pub const XDestroyWindowEvent = c.XDestroyWindowEvent;
pub const XMapRequestEvent = c.XMapRequestEvent;
pub const XUnmapEvent = c.XUnmapEvent;
pub const XResizeRequestEvent = c.XResizeRequestEvent;

// ── X window attributes / hints ─────────────────────────────────────────────
pub const XWindowAttributes = c.XWindowAttributes;
pub const XWindowChanges = c.XWindowChanges;
pub const XSetWindowAttributes = c.XSetWindowAttributes;
pub const XClassHint = c.XClassHint;
pub const XTextProperty = c.XTextProperty;
pub const XSizeHints = c.XSizeHints;
pub const XWMHints = c.XWMHints;
pub const XModifierKeymap = c.XModifierKeymap;
pub const XErrorEvent = c.XErrorEvent;

// ── Xft / fontconfig types ──────────────────────────────────────────────────
pub const XftColor = c.XftColor;
pub const XftFont = c.XftFont;
pub const XftDraw = c.XftDraw;
pub const XGlyphInfo = c.XGlyphInfo;
pub const FcPattern = c.FcPattern;
pub const FcCharSet = c.FcCharSet;
pub const FcResult = c.XftResult;

// ── Xinerama ────────────────────────────────────────────────────────────────
pub const XineramaScreenInfo = c.XineramaScreenInfo;

// ── General constants ───────────────────────────────────────────────────────
pub const None = c.None;
pub const True = c.True;
pub const False = c.False;
pub const CurrentTime = c.CurrentTime;
pub const PointerRoot = c.PointerRoot;
pub const AnyKey = c.AnyKey;
pub const AnyButton = c.AnyButton;
pub const AnyModifier = c.AnyModifier;
pub const GrabModeAsync = c.GrabModeAsync;
pub const GrabModeSync = c.GrabModeSync;
pub const GrabSuccess = c.GrabSuccess;
pub const RevertToPointerRoot = c.RevertToPointerRoot;
pub const NoEventMask = c.NoEventMask;
pub const PointerWindow = c.PointerWindow;

// ── Event masks (bitfields for XSelectInput) ────────────────────────────────
pub const SubstructureRedirectMask = c.SubstructureRedirectMask;
pub const SubstructureNotifyMask = c.SubstructureNotifyMask;
pub const ButtonPressMask = c.ButtonPressMask;
pub const ButtonReleaseMask = c.ButtonReleaseMask;
pub const PointerMotionMask = c.PointerMotionMask;
pub const EnterWindowMask = c.EnterWindowMask;
pub const LeaveWindowMask = c.LeaveWindowMask;
pub const StructureNotifyMask = c.StructureNotifyMask;
pub const PropertyChangeMask = c.PropertyChangeMask;
pub const FocusChangeMask = c.FocusChangeMask;
pub const ExposureMask = c.ExposureMask;
pub const ResizeRedirectMask = c.ResizeRedirectMask;
pub const KeyPressMask = c.KeyPressMask;

// ── Event types (XEvent.type values) ────────────────────────────────────────
pub const KeyPress = c.KeyPress;
pub const KeyRelease = c.KeyRelease;
pub const ButtonPress = c.ButtonPress;
pub const ButtonRelease = c.ButtonRelease;
pub const MotionNotify = c.MotionNotify;
pub const EnterNotify = c.EnterNotify;
pub const FocusIn = c.FocusIn;
pub const Expose = c.Expose;
pub const DestroyNotify = c.DestroyNotify;
pub const UnmapNotify = c.UnmapNotify;
pub const MapRequest = c.MapRequest;
pub const ConfigureNotify = c.ConfigureNotify;
pub const ConfigureRequest = c.ConfigureRequest;
pub const ClientMessage = c.ClientMessage;
pub const MappingNotify = c.MappingNotify;
pub const PropertyNotify = c.PropertyNotify;
pub const ResizeRequest = c.ResizeRequest;
pub const LASTEvent = c.LASTEvent;

// ── Notify modes/details (for Enter/FocusIn discrimination) ─────────────────
pub const NotifyNormal = c.NotifyNormal;
pub const NotifyInferior = c.NotifyInferior;
pub const MappingKeyboard = c.MappingKeyboard;

// ── CW (Change Window) attribute masks for XConfigureWindow / XCreateWindow ─
pub const CWX = c.CWX;
pub const CWY = c.CWY;
pub const CWWidth = c.CWWidth;
pub const CWHeight = c.CWHeight;
pub const CWBorderWidth = c.CWBorderWidth;
pub const CWSibling = c.CWSibling;
pub const CWStackMode = c.CWStackMode;
pub const CWEventMask = c.CWEventMask;
pub const CWCursor = c.CWCursor;
pub const CWOverrideRedirect = c.CWOverrideRedirect;
pub const CWBackPixmap = c.CWBackPixmap;
pub const CWBackPixel = c.CWBackPixel;

// ── Window stacking order ───────────────────────────────────────────────────
pub const Above = c.Above;
pub const Below = c.Below;

// ── Property modes (for XChangeProperty) ────────────────────────────────────
pub const PropModeReplace = c.PropModeReplace;
pub const PropModeAppend = c.PropModeAppend;
pub const PropertyDelete = c.PropertyDelete;

// ── WM state values (for WM_STATE property and map state) ───────────────────
pub const NormalState = c.NormalState;
pub const IconicState = c.IconicState;
pub const WithdrawnState = c.WithdrawnState;
pub const IsViewable = c.IsViewable;

// ── Predefined atoms (Xatom.h) ──────────────────────────────────────────────
pub const XA_ATOM = c.XA_ATOM;
pub const XA_WINDOW = c.XA_WINDOW;
pub const XA_CARDINAL = c.XA_CARDINAL;
pub const XA_STRING = c.XA_STRING;
pub const XA_WM_NAME = c.XA_WM_NAME;
pub const XA_WM_NORMAL_HINTS = c.XA_WM_NORMAL_HINTS;
pub const XA_WM_HINTS = c.XA_WM_HINTS;
pub const XA_WM_TRANSIENT_FOR = c.XA_WM_TRANSIENT_FOR;

// ── Cursor font shapes (cursorfont.h) ───────────────────────────────────────
pub const XC_left_ptr = c.XC_left_ptr;
pub const XC_sizing = c.XC_sizing;
pub const XC_fleur = c.XC_fleur;

// ── Modifier masks (for key/button grabs) ───────────────────────────────────
pub const ShiftMask = c.ShiftMask;
pub const LockMask = c.LockMask;
pub const ControlMask = c.ControlMask;
pub const Mod1Mask = c.Mod1Mask;
pub const Mod2Mask = c.Mod2Mask;
pub const Mod3Mask = c.Mod3Mask;
pub const Mod4Mask = c.Mod4Mask;
pub const Mod5Mask = c.Mod5Mask;

// ── Mouse buttons ───────────────────────────────────────────────────────────
pub const Button1 = c.Button1;
pub const Button2 = c.Button2;
pub const Button3 = c.Button3;

// ── Key symbols (keysym.h) ──────────────────────────────────────────────────
pub const XK_Return = c.XK_Return;
pub const XK_Tab = c.XK_Tab;
pub const XK_space = c.XK_space;
pub const XK_Num_Lock = c.XK_Num_Lock;
pub const XK_F1 = c.XK_F1;
pub const XK_p = c.XK_p;
pub const XK_b = c.XK_b;
pub const XK_j = c.XK_j;
pub const XK_k = c.XK_k;
pub const XK_i = c.XK_i;
pub const XK_d = c.XK_d;
pub const XK_h = c.XK_h;
pub const XK_l = c.XK_l;
pub const XK_t = c.XK_t;
pub const XK_f = c.XK_f;
pub const XK_m = c.XK_m;
pub const XK_s = c.XK_s;
pub const XK_e = c.XK_e;
pub const XK_q = c.XK_q;
// BEPO number-row keys (produce punctuation, not digits)
pub const XK_quotedbl = c.XK_quotedbl;
pub const XK_guillemotleft = c.XK_guillemotleft;
pub const XK_guillemotright = c.XK_guillemotright;
pub const XK_parenleft = c.XK_parenleft;
pub const XK_parenright = c.XK_parenright;
pub const XK_at = c.XK_at;
pub const XK_plus = c.XK_plus;
pub const XK_minus = c.XK_minus;
pub const XK_slash = c.XK_slash;
pub const XK_asterisk = c.XK_asterisk;
pub const XK_comma = c.XK_comma;
pub const XK_period = c.XK_period;

// ── Size hint flags (from XSizeHints) ───────────────────────────────────────
pub const PSize = c.PSize;
pub const PBaseSize = c.PBaseSize;
pub const PMinSize = c.PMinSize;
pub const PMaxSize = c.PMaxSize;
pub const PResizeInc = c.PResizeInc;
pub const PAspect = c.PAspect;

// ── WM hint flags ───────────────────────────────────────────────────────────
pub const XUrgencyHint = c.XUrgencyHint;
pub const InputHint = c.InputHint;

// ── X Protocol request codes (for error handler discrimination) ─────────────
pub const X_SetInputFocus = c.X_SetInputFocus;
pub const X_PolyText8 = c.X_PolyText8;
pub const X_PolyFillRectangle = c.X_PolyFillRectangle;
pub const X_PolySegment = c.X_PolySegment;
pub const X_ConfigureWindow = c.X_ConfigureWindow;
pub const X_GrabButton = c.X_GrabButton;
pub const X_GrabKey = c.X_GrabKey;
pub const X_CopyArea = c.X_CopyArea;

// ── X error codes ───────────────────────────────────────────────────────────
pub const BadWindow = c.BadWindow;
pub const BadDrawable = c.BadDrawable;
pub const BadMatch = c.BadMatch;
pub const BadAccess = c.BadAccess;
pub const Success = c.Success;

// ── Miscellaneous X constants ────────────────────────────────────────────────
pub const CopyFromParent = c.CopyFromParent;
pub const ParentRelative = c.ParentRelative;
pub const DestroyAll = c.DestroyAll;
pub const ReplayPointer = c.ReplayPointer;
pub const LineSolid = c.LineSolid;
pub const CapButt = c.CapButt;
pub const JoinMiter = c.JoinMiter;

// ── Fontconfig constants ────────────────────────────────────────────────────
pub const FC_COLOR = c.FC_COLOR;
pub const FC_CHARSET = c.FC_CHARSET;
pub const FC_SCALABLE = c.FC_SCALABLE;
pub const FcTrue = c.FcTrue;
pub const FcFalse = c.FcFalse;
pub const FcResultMatch = c.FcResultMatch;
pub const FcMatchPattern = c.FcMatchPattern;
