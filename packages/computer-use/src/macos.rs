//! Documented ScreenCaptureKit, CoreGraphics and AppKit APIs only. No permission
//! requests, clipboard mutation, AppleScript, shell tool, or arbitrary code tool.
use crate::{
    contract::*,
    executor::{CapturedFrame, Desktop, Target},
};
use core_foundation::{
    base::{CFType, TCFType},
    dictionary::CFDictionary,
    number::CFNumber,
    string::CFString,
};
use core_graphics::{
    access::ScreenCaptureAccess,
    window::{
        copy_window_info, kCGWindowListExcludeDesktopElements, kCGWindowListOptionOnScreenOnly,
    },
};
use enigo::{Axis, Coordinate, Direction, Enigo, Keyboard, Mouse, Settings};
use objc2::rc::autoreleasepool;
use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication, NSWorkspace};
use screencapturekit::{
    prelude::*,
    screenshot_manager::{CGImageExt, SCScreenshotManager},
};
use std::sync::atomic::{AtomicBool, Ordering};

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
}

/// Harmless checks only: never opens a TCC prompt.
pub fn permissions() -> (bool, bool) {
    // SAFETY: documented no-argument system query, without prompt options.
    (ScreenCaptureAccess.preflight(), unsafe {
        AXIsProcessTrusted()
    })
}

// One native adapter per process, never released for automatic retry after faults.
// Host integration must also own the desktop across processes.
static CLAIMED: AtomicBool = AtomicBool::new(false);
pub struct MacDesktop {
    input: Enigo,
}
impl MacDesktop {
    pub fn new() -> Result<Self, String> {
        if permissions() != (true, true) {
            return Err("existing Screen Recording and Accessibility permissions required".into());
        }
        if CLAIMED.swap(true, Ordering::SeqCst) {
            return Err("native desktop already owned in this process".into());
        }
        let input = Enigo::new(&Settings {
            open_prompt_to_get_permissions: false,
            ..Settings::default()
        })
        .map_err(|e| e.to_string())?;
        Ok(Self { input })
    }
    fn scoped(target: &Target) -> Result<(SCWindow, DisplayTransform), String> {
        if !ScreenCaptureAccess.preflight() {
            return Err("Screen Recording permission unavailable".into());
        }
        let content = SCShareableContent::get().map_err(|e| e.to_string())?;
        let window = content
            .windows()
            .into_iter()
            .find(|w| {
                w.window_id() == target.window_id
                    && w.is_on_screen()
                    && w.window_layer() == 0
                    && w.owning_application()
                        .is_some_and(|a| a.process_id() == target.process_id)
            })
            .ok_or("authorized window unavailable")?;
        let display = content
            .displays()
            .into_iter()
            .find(|d| d.display_id() == target.display_id)
            .ok_or("authorized display unavailable")?;
        let rect = |r: screencapturekit::cg::CGRect| Rect {
            x: r.origin.x,
            y: r.origin.y,
            width: r.size.width,
            height: r.size.height,
        };
        let window_frame = rect(window.frame());
        let scale = (1600.0 / window_frame.width.max(window_frame.height)).min(1.0);
        let transform = DisplayTransform {
            display_id: target.display_id,
            display_frame: rect(display.frame()),
            window_id: target.window_id,
            window_frame,
            pixel_width: (window_frame.width * scale).round().max(1.0) as u32,
            pixel_height: (window_frame.height * scale).round().max(1.0) as u32,
        };
        transform.validate()?;
        Ok((window, transform))
    }
}

/// Front-to-back CoreGraphics list: fail closed if another app/window or modal
/// panel is above the permitted window. Menubar/dock layers are not document windows.
fn foreground_window() -> Result<(i32, u32), String> {
    let list = copy_window_info(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
        0,
    )
    .ok_or("window list unavailable")?;
    for raw in list.iter() {
        // SAFETY: CGWindowListCopyWindowInfo returns retained CFDictionary entries.
        // Runtime downcasts verify the dictionary and numbers before access.
        let value = unsafe { CFType::wrap_under_get_rule(*raw) };
        let Some(dict) = value.downcast::<CFDictionary>() else {
            return Err("invalid window dictionary".into());
        };
        let number = |key: &str| -> Option<i64> {
            let key = CFString::new(key);
            let raw = dict.find(key.as_CFTypeRef())?;
            // SAFETY: dictionary values are CFType objects, kept alive by `dict`.
            let value = unsafe { CFType::wrap_under_get_rule(*raw) };
            value.downcast::<CFNumber>()?.to_i64()
        };
        if number("kCGWindowLayer") == Some(0) {
            let pid = number("kCGWindowOwnerPID")
                .and_then(|n| i32::try_from(n).ok())
                .ok_or("missing window pid")?;
            let id = number("kCGWindowNumber")
                .and_then(|n| u32::try_from(n).ok())
                .ok_or("missing window id")?;
            return Ok((pid, id));
        }
    }
    Err("no foreground document window".into())
}

impl Desktop for MacDesktop {
    fn capture(&mut self, target: &Target) -> Result<CapturedFrame, String> {
        autoreleasepool(|_| {
            let (window, transform) = Self::scoped(target)?;
            let filter = SCContentFilter::create()
                .with_window(&window)
                .build()
                .map_err(|e| e.to_string())?;
            let config = SCStreamConfiguration::new()
                .with_width(transform.pixel_width)
                .with_height(transform.pixel_height)
                .with_shows_cursor(false)
                .with_ignores_shadows_single_window(true)
                .map_err(|e| e.to_string())?;
            let image =
                SCScreenshotManager::capture_image(&filter, &config).map_err(|e| e.to_string())?;
            if image.width() != transform.pixel_width as usize
                || image.height() != transform.pixel_height as usize
            {
                return Err("capture dimensions changed".into());
            }
            let rgba = image.rgba_data().map_err(|e| e.to_string())?;
            // Recheck geometry after capture; moved/resized windows need a new observation.
            if Self::scoped(target)?.1 != transform {
                return Err("window/display changed during capture".into());
            }
            let mut png = Vec::new();
            {
                let mut encoder =
                    png::Encoder::new(&mut png, transform.pixel_width, transform.pixel_height);
                encoder.set_color(png::ColorType::Rgba);
                encoder.set_depth(png::BitDepth::Eight);
                let mut writer = encoder.write_header().map_err(|e| e.to_string())?;
                writer.write_image_data(&rgba).map_err(|e| e.to_string())?;
                writer.finish().map_err(|e| e.to_string())?;
            }
            Ok(CapturedFrame { transform, png })
        })
    }
    fn preflight(
        &mut self,
        target: &Target,
        expected: Option<&DisplayTransform>,
        focus: bool,
    ) -> Result<(), String> {
        autoreleasepool(|_| {
            if permissions() != (true, true) {
                return Err("desktop permissions unavailable".into());
            }
            let (_, transform) = Self::scoped(target)?;
            if expected.is_some_and(|e| *e != transform) {
                return Err("display/window transform changed; observe again".into());
            }
            let frontmost = NSWorkspace::sharedWorkspace()
                .frontmostApplication()
                .map(|app| app.processIdentifier());
            if !focus
                && (frontmost != Some(target.process_id)
                    || foreground_window()? != (target.process_id, target.window_id))
            {
                return Err("authorized window must be foreground".into());
            }
            Ok(())
        })
    }
    fn perform(
        &mut self,
        target: &Target,
        action: &Action,
        point: Option<(i32, i32)>,
    ) -> Result<(), String> {
        autoreleasepool(|_| {
            if let Some((x, y)) = point {
                self.input
                    .move_mouse(x, y, Coordinate::Abs)
                    .map_err(|e| e.to_string())?;
            }
            let result = match action {
                Action::Move { .. } => Ok(()),
                Action::Click { button, .. } => self.input.button(
                    match button {
                        Button::Left => enigo::Button::Left,
                        Button::Right => enigo::Button::Right,
                        Button::Middle => enigo::Button::Middle,
                    },
                    Direction::Click,
                ),
                Action::Scroll {
                    vertical,
                    horizontal,
                    ..
                } => {
                    self.input
                        .scroll(*vertical, Axis::Vertical)
                        .map_err(|e| e.to_string())?;
                    self.input.scroll(*horizontal, Axis::Horizontal)
                }
                Action::Text { text, .. } => self.input.text(text),
                Action::Key { key, .. } => self.input.key(
                    match key {
                        Key::Return => enigo::Key::Return,
                        Key::Tab => enigo::Key::Tab,
                        Key::Escape => enigo::Key::Escape,
                        Key::Backspace => enigo::Key::Backspace,
                        Key::Left => enigo::Key::LeftArrow,
                        Key::Right => enigo::Key::RightArrow,
                        Key::Up => enigo::Key::UpArrow,
                        Key::Down => enigo::Key::DownArrow,
                    },
                    Direction::Click,
                ),
                Action::Focus {} => {
                    let app = NSRunningApplication::runningApplicationWithProcessIdentifier(
                        target.process_id,
                    )
                    .ok_or("authorized application exited")?;
                    #[allow(deprecated)]
                    if !app.activateWithOptions(NSApplicationActivationOptions::empty()) {
                        return Err("application activation failed".into());
                    }
                    // Activation is asynchronous; subsequent input still requires a fresh
                    // screenshot and exact foreground-window preflight.
                    return Ok(());
                }
                _ => return Err("non-input action sent to native input adapter".into()),
            };
            result.map_err(|e| e.to_string())
        })
    }
}
