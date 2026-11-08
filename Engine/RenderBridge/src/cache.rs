//! A least-recently-used cache of rendered blocks within a byte budget.

use std::collections::{BTreeMap, HashMap};
use std::sync::Arc;

use typst::syntax::FileId;

use crate::Rendered;

/// The default byte budget: 64 MB.
pub const DEFAULT_BUDGET: usize = 64 * 1024 * 1024;

/// Counts for tests and tuning. The same layout as `PRCacheStats`.
#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct CacheStats {
    pub entries: u64,
    pub bytes: u64,
    pub budget: u64,
    pub hits: u64,
    pub misses: u64,
}

/// The files a render read, with the version each had then.
pub(crate) type Dependencies = Vec<(FileId, u64)>;

struct Entry {
    value: Arc<Rendered>,
    dependencies: Dependencies,
    bytes: usize,
    tick: u64,
}

/// Keyed by a hash of the complete block document and the width. An entry is
/// also checked against the versions of the files its render read (imports,
/// images), since the key holds only their names.
pub(crate) struct Cache {
    budget: usize,
    bytes: usize,
    tick: u64,
    hits: u64,
    misses: u64,
    entries: HashMap<u128, Entry>,
    order: BTreeMap<u64, u128>,
}

impl Cache {
    pub(crate) fn new(budget: usize) -> Self {
        Self {
            budget: if budget == 0 { DEFAULT_BUDGET } else { budget },
            bytes: 0,
            tick: 0,
            hits: 0,
            misses: 0,
            entries: HashMap::new(),
            order: BTreeMap::new(),
        }
    }

    /// The entry for `key` if its dependencies are still current, marked as
    /// most recently used. Counts a hit or a miss.
    pub(crate) fn get(
        &mut self,
        key: u128,
        current: impl Fn(&Dependencies) -> bool,
    ) -> Option<Arc<Rendered>> {
        let valid = self
            .entries
            .get(&key)
            .map(|entry| current(&entry.dependencies));
        match valid {
            Some(true) => {
                self.hits += 1;
                self.tick += 1;
                let entry = self.entries.get_mut(&key).expect("entry present");
                self.order.remove(&entry.tick);
                entry.tick = self.tick;
                self.order.insert(self.tick, key);
                Some(entry.value.clone())
            }
            Some(false) => {
                self.misses += 1;
                self.remove(key);
                None
            }
            None => {
                self.misses += 1;
                None
            }
        }
    }

    pub(crate) fn insert(&mut self, key: u128, value: Arc<Rendered>, dependencies: Dependencies) {
        self.remove(key);
        let bytes = value.bytes() + dependencies.len() * std::mem::size_of::<(FileId, u64)>() + 64;
        if bytes > self.budget {
            return;
        }
        self.tick += 1;
        self.bytes += bytes;
        self.order.insert(self.tick, key);
        self.entries.insert(
            key,
            Entry {
                value,
                dependencies,
                bytes,
                tick: self.tick,
            },
        );
        while self.bytes > self.budget {
            let Some((_, oldest)) = self.order.pop_first() else {
                break;
            };
            if let Some(entry) = self.entries.remove(&oldest) {
                self.bytes -= entry.bytes;
            }
        }
    }

    fn remove(&mut self, key: u128) {
        if let Some(entry) = self.entries.remove(&key) {
            self.order.remove(&entry.tick);
            self.bytes -= entry.bytes;
        }
    }

    pub(crate) fn stats(&self) -> CacheStats {
        CacheStats {
            entries: self.entries.len() as u64,
            bytes: self.bytes as u64,
            budget: self.budget as u64,
            hits: self.hits,
            misses: self.misses,
        }
    }
}
