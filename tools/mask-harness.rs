// The entry point of the mask harness.
//
// The masking block below is copied verbatim from upstream A2DP-Windows-Bridge
// (app/src/crates/core/src/diag.rs, the merged state) by
// scripts/check-merged-mask.ps1, which replaces the marker line below with
// it. Only this file is ours.
//
// The masker is seeded the way app/src/core/src/bundle.rs seeds it
// (masker.know(name); masker.know_adapter(address);). Without the names the
// device names are not masked, and the check would be misleading.

use std::io::Read;

@@MASK_BLOCK@@

fn main() {
    // argv[1] = the file to mask
    // argv[2] = the file to write
    // argv[3..] = the names the app tells the masker (the profile's, the
    // devices'), the last one = the adapter's own address
    let args: Vec<String> = std::env::args().collect();
    let mut input = String::new();
    std::fs::File::open(&args[1])
        .unwrap()
        .read_to_string(&mut input)
        .unwrap();

    let mut masker = Masker::new();
    if args.len() > 3 {
        for name in &args[3..args.len() - 1] {
            masker.know(name);
        }
        masker.know_adapter(&args[args.len() - 1]);
    }

    let out = masker.mask(&input);
    std::fs::write(&args[2], out).unwrap();
}
