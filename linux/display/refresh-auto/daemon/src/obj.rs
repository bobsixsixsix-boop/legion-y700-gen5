//! The exported object, fyi.y700.RefreshAuto at /RefreshAuto, answered the way GDBus answered for the Python version
//! (GLib 2.88's gdbusconnection.c: obj_message_func, then handle_generic_unlocked, then its two "not found" errors) -
//! the introspection XML byte for byte, the standard interfaces on the object, the generic Introspect / Ping /
//! GetMachineId on every path, and the same error names and texts (recorded from the running Python daemon, 11-03).
//! The KWin script and `gdbus call` see no difference.

use crate::dbus::{string_body, Msg, R};

pub const PATH: &str = "/RefreshAuto";
pub const IFACE: &str = "fyi.y700.RefreshAuto";
const INTROSPECTABLE: &str = "org.freedesktop.DBus.Introspectable";
const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
const PEER: &str = "org.freedesktop.DBus.Peer";
const UNKNOWN_METHOD: &str = "org.freedesktop.DBus.Error.UnknownMethod";
const INVALID_ARGS: &str = "org.freedesktop.DBus.Error.InvalidArgs";

const HEAD: &str = "<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"
                      \"http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd\">
<!-- GDBus 2.88.0 -->
";

/// /RefreshAuto: GDBus's standard interfaces, then ours as g_dbus_interface_info_generate_xml writes it.
const OBJECT: &str = r#"<node>
  <interface name="org.freedesktop.DBus.Properties">
    <method name="Get">
      <arg type="s" name="interface_name" direction="in"/>
      <arg type="s" name="property_name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="GetAll">
      <arg type="s" name="interface_name" direction="in"/>
      <arg type="a{sv}" name="properties" direction="out"/>
    </method>
    <method name="Set">
      <arg type="s" name="interface_name" direction="in"/>
      <arg type="s" name="property_name" direction="in"/>
      <arg type="v" name="value" direction="in"/>
    </method>
    <signal name="PropertiesChanged">
      <arg type="s" name="interface_name"/>
      <arg type="a{sv}" name="changed_properties"/>
      <arg type="as" name="invalidated_properties"/>
    </signal>
  </interface>
  <interface name="org.freedesktop.DBus.Introspectable">
    <method name="Introspect">
      <arg type="s" name="xml_data" direction="out"/>
    </method>
  </interface>
  <interface name="org.freedesktop.DBus.Peer">
    <method name="Ping"/>
    <method name="GetMachineId">
      <arg type="s" name="machine_uuid" direction="out"/>
    </method>
  </interface>
  <interface name="fyi.y700.RefreshAuto">
    <method name="activeWindow">
      <arg type="s" name="resourceClass" direction="in">
      </arg>
      <arg type="b" name="covers" direction="in">
      </arg>
      <arg type="i" name="pid" direction="in">
      </arg>
    </method>
    <method name="status">
      <arg type="s" name="json" direction="out">
      </arg>
    </method>
  </interface>
</node>
"#;

/// What to do with a method call.
#[derive(Debug, PartialEq)]
pub enum Route {
    /// answer with this signature and body
    Reply(&'static str, Vec<u8>),
    /// answer with this error
    Error(&'static str, String),
    /// our methods: the caller answers (activeWindow with an empty reply, sent before the decision runs)
    ActiveWindow(String, bool, i32),
    Status,
}

/// Generic introspection of a path that is not the object: its child nodes (only / has one).
fn introspect(path: &str, exported: bool) -> String {
    let child = if exported && path == "/" { "  <node name=\"RefreshAuto\"/>\n" } else { "" };
    format!("{HEAD}<node>\n{child}</node>\n")
}

/// GLib's _g_dbus_get_machine_id(): D-Bus's file, else systemd's, whitespace stripped.
fn machine_id() -> Result<String, String> {
    let first = std::fs::read_to_string("/var/lib/dbus/machine-id");
    match first.or_else(|_| std::fs::read_to_string("/etc/machine-id")) {
        Ok(s) => Ok(s.trim().to_string()),
        // shortcut: GLib's text is "Unable to load ... : Failed to open file “...”: <strerror>"; no tablet lacks both
        Err(e) => Err(format!("Unable to load /var/lib/dbus/machine-id or /etc/machine-id: {e}")),
    }
}

/// Routes a method call to us. `exported`: the session connection, which carries the object; the system connection
/// has only the generic handlers (as Python's second GDBus connection).
pub fn route(m: &Msg, exported: bool) -> Route {
    let (member, sig) = (m.member.as_str(), m.signature.as_str());
    let mut found = false;
    if exported && m.path == PATH {
        // obj_message_func: a call without an interface matches nothing here (found stays false)
        if let Some(iface) = m.iface.as_deref() {
            if iface == IFACE {
                let bad = |want: &str| Route::Error(INVALID_ARGS, format!("Type of message, “({sig})”, does not match expected type “{want}”"));
                return match member {
                    "activeWindow" if sig == "sbi" => {
                        // the bus checked the body against the signature
                        let mut r = R::new(&m.body);
                        let cls = r.string().unwrap_or_default();
                        let covers = r.u32().unwrap_or(0) != 0;
                        Route::ActiveWindow(cls, covers, r.u32().unwrap_or(0) as i32)
                    }
                    "activeWindow" => bad("(sbi)"),
                    "status" if sig.is_empty() => Route::Status,
                    "status" => bad("()"),
                    _ => Route::Error(UNKNOWN_METHOD, format!("No such method “{member}”")),
                };
            }
            found = true;
            let mut r = R::new(&m.body);
            match (iface, member, sig) {
                (INTROSPECTABLE, "Introspect", "") => return Route::Reply("s", string_body(&format!("{HEAD}{OBJECT}"))),
                (PROPERTIES, "Get", "ss") | (PROPERTIES, "Set", "ssv") => {
                    let (i, p) = (r.string().unwrap_or_default(), r.string().unwrap_or_default());
                    let text = if i == IFACE { format!("No such property “{p}”") } else { format!("No such interface “{i}”") };
                    return Route::Error(INVALID_ARGS, text);
                }
                (PROPERTIES, "GetAll", "s") => {
                    let i = r.string().unwrap_or_default();
                    if i != IFACE {
                        return Route::Error(INVALID_ARGS, format!("No such interface “{i}”"));
                    }
                    // no properties: an empty a{sv} (its length, padded to the dict entries' 8)
                    return Route::Reply("a{sv}", vec![0; 8]);
                }
                _ => {}
            }
        }
    }
    match (m.iface.as_deref(), member, sig) {
        (Some(INTROSPECTABLE), "Introspect", "") => Route::Reply("s", string_body(&introspect(&m.path, exported))),
        (Some(PEER), "Ping", "") => Route::Reply("", Vec::new()),
        (Some(PEER), "GetMachineId", "") => match machine_id() {
            Ok(id) => Route::Reply("s", string_body(&id)),
            Err(e) => Route::Error("org.freedesktop.DBus.Error.Failed", e),
        },
        _ if found => Route::Error(UNKNOWN_METHOD, format!("No such interface “{}” on object at path {}", m.iface.as_deref().unwrap_or(""), m.path)),
        _ => Route::Error(UNKNOWN_METHOD, format!("Object does not exist at path “{}”", m.path)),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dbus::tests::{message, read_one};
    use crate::dbus::{W, METHOD_CALL};

    fn call(path: &str, iface: &str, member: &str, sig: &str, body: &[u8]) -> Msg {
        read_one(&message(METHOD_CALL, 7, path, iface, member, None, sig, body))
    }

    fn strings(v: &[&str]) -> Vec<u8> {
        let mut w = W(Vec::new());
        for s in v {
            w.string(s);
        }
        w.0
    }

    fn reply_string(r: Route) -> String {
        match r {
            Route::Reply("s", b) => R::new(&b).string().unwrap(),
            r => panic!("{r:?}"),
        }
    }

    fn err(name: &'static str, text: &str) -> Route {
        Route::Error(name, text.to_string())
    }

    #[test]
    fn our_methods() {
        let mut w = W(Vec::new());
        w.string("mpv");
        w.u32(1);
        w.u32(4242);
        assert_eq!(route(&call(PATH, IFACE, "activeWindow", "sbi", &w.0), true), Route::ActiveWindow("mpv".into(), true, 4242));
        let mut w = W(Vec::new());
        w.string("");
        w.u32(0);
        w.u32(-1i32 as u32);
        assert_eq!(route(&call(PATH, IFACE, "activeWindow", "sbi", &w.0), true), Route::ActiveWindow("".into(), false, -1));
        assert_eq!(route(&call(PATH, IFACE, "status", "", &[]), true), Route::Status);
        // as recorded from the Python daemon (GDBus 2.88.0)
        assert_eq!(route(&call(PATH, IFACE, "status", "s", &strings(&["x"])), true),
            err(INVALID_ARGS, "Type of message, “(s)”, does not match expected type “()”"));
        assert_eq!(route(&call(PATH, IFACE, "activeWindow", "", &[]), true),
            err(INVALID_ARGS, "Type of message, “()”, does not match expected type “(sbi)”"));
        assert_eq!(route(&call(PATH, IFACE, "nope", "", &[]), true), err(UNKNOWN_METHOD, "No such method “nope”"));
        assert_eq!(route(&call(PATH, "a.b", "x", "", &[]), true), err(UNKNOWN_METHOD, "No such interface “a.b” on object at path /RefreshAuto"));
        assert_eq!(route(&call("/Nope", IFACE, "status", "", &[]), true), err(UNKNOWN_METHOD, "Object does not exist at path “/Nope”"));
        // no interface: nothing on the object matches it, and the generic handlers want one
        assert_eq!(route(&call(PATH, "", "status", "", &[]), true), err(UNKNOWN_METHOD, "Object does not exist at path “/RefreshAuto”"));
        // the system connection exports nothing
        assert_eq!(route(&call(PATH, IFACE, "status", "", &[]), false), err(UNKNOWN_METHOD, "Object does not exist at path “/RefreshAuto”"));
    }

    #[test]
    fn standard_interfaces() {
        let x = reply_string(route(&call(PATH, INTROSPECTABLE, "Introspect", "", &[]), true));
        assert!(x.starts_with("<!DOCTYPE node PUBLIC \"-//freedesktop//DTD D-BUS Object Introspection 1.0//EN\"\n                      \"http://"));
        assert!(x.ends_with("      <arg type=\"s\" name=\"json\" direction=\"out\">\n      </arg>\n    </method>\n  </interface>\n</node>\n"));
        assert_eq!(x.matches("<interface ").count(), 4);
        assert_eq!(reply_string(route(&call("/", INTROSPECTABLE, "Introspect", "", &[]), true)),
            format!("{HEAD}<node>\n  <node name=\"RefreshAuto\"/>\n</node>\n"));
        for path in ["/Nope", "/RefreshAuto/x"] {
            assert_eq!(reply_string(route(&call(path, INTROSPECTABLE, "Introspect", "", &[]), true)), format!("{HEAD}<node>\n</node>\n"));
        }
        assert_eq!(reply_string(route(&call("/", INTROSPECTABLE, "Introspect", "", &[]), false)), format!("{HEAD}<node>\n</node>\n"));
        assert_eq!(route(&call(PATH, PEER, "Ping", "", &[]), true), Route::Reply("", Vec::new()));
        assert_eq!(route(&call("/", PEER, "Ping", "", &[]), false), Route::Reply("", Vec::new()));
        assert!(matches!(route(&call("/Nope", PEER, "GetMachineId", "", &[]), true), Route::Reply("s", _) | Route::Error(..)));
        assert_eq!(route(&call(PATH, PROPERTIES, "GetAll", "s", &strings(&[IFACE])), true), Route::Reply("a{sv}", vec![0; 8]));
        assert_eq!(route(&call(PATH, PROPERTIES, "GetAll", "s", &strings(&["a.b"])), true), err(INVALID_ARGS, "No such interface “a.b”"));
        assert_eq!(route(&call(PATH, PROPERTIES, "Get", "ss", &strings(&[IFACE, "x"])), true), err(INVALID_ARGS, "No such property “x”"));
        assert_eq!(route(&call(PATH, PROPERTIES, "Get", "ss", &strings(&["a.b", "x"])), true), err(INVALID_ARGS, "No such interface “a.b”"));
        // a standard interface with the wrong signature: not handled, and the object exists
        assert_eq!(route(&call(PATH, PROPERTIES, "Get", "s", &strings(&[IFACE])), true),
            err(UNKNOWN_METHOD, "No such interface “org.freedesktop.DBus.Properties” on object at path /RefreshAuto"));
        assert_eq!(route(&call("/", PROPERTIES, "GetAll", "s", &strings(&[IFACE])), true), err(UNKNOWN_METHOD, "Object does not exist at path “/”"));
    }
}
