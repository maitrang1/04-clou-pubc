// Exit codes (documented in .10-docs/15-FEAT.md). One place so commands never invent numbers.
pub const OK: u8 = 0;
pub const FAILED: u8 = 1;
pub const USAGE: u8 = 2; // usage or config problem
pub const BLOCKED: u8 = 3; // kill file, breaker, cap, quota, dead token
pub const NOTHING: u8 = 4; // nothing to do
pub const UNSURE: u8 = 5; // answer lost after finish: run resolve
