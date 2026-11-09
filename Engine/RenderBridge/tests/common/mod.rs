//! Shared helpers: throwaway projects in the temporary folder.

#![allow(dead_code)]

use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};

use std::path::Path;

use prose_render::{BlockRange, Engine, Options};

/// A project folder that is removed when dropped.
pub struct Project {
    pub root: PathBuf,
}

impl Project {
    pub fn new(files: &[(&str, &str)]) -> Self {
        static NEXT: AtomicUsize = AtomicUsize::new(0);
        let root = std::env::temp_dir().join(format!(
            "prose-render-test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        let _ = std::fs::remove_dir_all(&root);
        for (name, text) in files {
            let path = root.join(name);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        Self {
            root: root.canonicalize().unwrap(),
        }
    }

    pub fn path(&self, name: &str) -> PathBuf {
        self.root.join(name)
    }

    pub fn engine(&self) -> Engine {
        Engine::new(Options::new(&self.root, "main.typ")).unwrap()
    }
}

impl Drop for Project {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// The UTF-16 offset of the first occurrence of `needle` in `text`.
pub fn utf16_index(text: &str, needle: &str) -> usize {
    let byte = text
        .find(needle)
        .unwrap_or_else(|| panic!("{needle:?} not in text"));
    text[..byte].encode_utf16().count()
}

/// The text of a UTF-16 range.
pub fn utf16_slice(text: &str, start: usize, end: usize) -> String {
    let units: Vec<u16> = text.encode_utf16().collect();
    String::from_utf16(&units[start..end]).unwrap()
}

/// The blocks of a file that render: not context, include or comment blocks.
pub fn rendering_blocks(engine: &Engine, path: &Path) -> Vec<BlockRange> {
    engine
        .blocks(path)
        .unwrap()
        .into_iter()
        .filter(|b| b.kind.renders())
        .collect()
}
