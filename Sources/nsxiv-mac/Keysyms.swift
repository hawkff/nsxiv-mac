#if os(Linux)
import CX11

// The key name the bindings use: printable ASCII as typed, other keys by their keysym
// name; a modifier alone is no key. X11 and xkbcommon share keysym values and names.
func keyName(forKeysym sym: UInt) -> String? {
    switch sym {
    case 0x20...0x7e: return String(UnicodeScalar(UInt8(sym)))
    case UInt(XK_Shift_L)...UInt(XK_Hyper_R), UInt(XK_Mode_switch), UInt(XK_Num_Lock),
         UInt(XK_ISO_Level3_Shift), UInt(NoSymbol): return nil
    default: return XKeysymToString(KeySym(sym)).map { String(cString: $0) }
    }
}
#endif
