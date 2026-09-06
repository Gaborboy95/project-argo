//! Small process-wide runtime filter; no payload logging or formatting when off.
use std::{
    fmt,
    sync::OnceLock,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Level {
    Error,
    Warn,
    Info,
    Debug,
    Trace,
}

impl Level {
    pub fn parse(value: &str) -> Result<Self, String> {
        match value {
            "error" => Ok(Self::Error),
            "warn" => Ok(Self::Warn),
            "info" => Ok(Self::Info),
            "debug" => Ok(Self::Debug),
            "trace" => Ok(Self::Trace),
            _ => Err("ARGO_PROJECTION_LOG_LEVEL must be error|warn|info|debug|trace".into()),
        }
    }
}
static LEVEL: OnceLock<Level> = OnceLock::new();
pub fn init() -> Result<(), String> {
    let level = Level::parse(
        &std::env::var("ARGO_PROJECTION_LOG_LEVEL").unwrap_or_else(|_| "info".into()),
    )?;
    let _ = LEVEL.set(level);
    Ok(())
}
pub fn enabled(level: Level) -> bool {
    level <= *LEVEL.get_or_init(|| Level::Info)
}
pub fn emit(level: Level, component: &str, args: fmt::Arguments<'_>) {
    let time = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    eprintln!(
        "{}.{:03} {level:?} [{component}] {args}",
        time.as_secs(),
        time.subsec_millis()
    );
}
#[macro_export]
macro_rules! daemon_log {
    ($level:ident, $component:expr, $($args:tt)*) => {
        if $crate::logging::enabled($crate::logging::Level::$level) {
            $crate::logging::emit($crate::logging::Level::$level, $component, format_args!($($args)*));
        }
    };
}
