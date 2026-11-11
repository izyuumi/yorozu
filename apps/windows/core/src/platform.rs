use rand_core::{OsRng, RngCore};
use std::{
    future::Future,
    path::PathBuf,
    pin::Pin,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
pub trait Platform: Send + Sync {
    fn now_ms(&self) -> u64;
    fn random_bytes(&self, bytes: &mut [u8]);
    fn computer_name(&self) -> String;
    fn data_dir(&self) -> PathBuf;
    fn sleep(&self, duration: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>>;
}
pub struct SystemPlatform {
    pub dir: PathBuf,
}
impl Platform for SystemPlatform {
    fn now_ms(&self) -> u64 {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis() as u64
    }
    fn random_bytes(&self, b: &mut [u8]) {
        OsRng.fill_bytes(b);
    }
    fn computer_name(&self) -> String {
        std::env::var("COMPUTERNAME")
            .or_else(|_| std::env::var("HOSTNAME"))
            .unwrap_or_else(|_| "Windows PC".into())
    }
    fn data_dir(&self) -> PathBuf {
        self.dir.clone()
    }
    fn sleep(&self, d: Duration) -> Pin<Box<dyn Future<Output = ()> + Send>> {
        Box::pin(tokio::time::sleep(d))
    }
}
