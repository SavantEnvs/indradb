#![no_main]
//! fuzz_targets/identifier.rs — exercises only `indradb::Identifier::new`, the
//! validation entry point used for every vertex/edge type and property name
//! throughout the database (`lib/src/models/identifiers.rs`). Pure function
//! of the fuzzer's bytes: interned into a process-global `Intern<String>`
//! table (via the `internment` crate) on success, so this also stresses that
//! interner under adversarial/duplicate input. No filesystem, no network.

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Ok(s) = std::str::from_utf8(data) else {
        return;
    };
    let _ = indradb::Identifier::new(s.to_string());
});
