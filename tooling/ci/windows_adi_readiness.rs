//! Private readiness probe, not an Anisette provider or account login.
//! Protocol reference: Dadoum/apple-crates f9cbefde2bf72fa9becfedc8da64827d4549849a,
//! adi/src/{calls,core_adi}.rs and library-coreadi/src/windows.rs.
//! Only initialize, query the shared GrandSlam machine slot, and finalize.
//! Never enumerate accounts, request OTP material, provision, erase, or log in.

use std::{ffi::c_void, os::windows::ffi::OsStrExt, path::PathBuf};

const INITIALIZE: u32 = 0x12db31c5;
const IS_PROVISIONED: u32 = 0xb0eda7af;
const FINALIZE: u32 = 0x08c0fe9e;

#[repr(C)]
struct Parameters {
    payload: *mut u8,
    input_size: u32,
    output_size: u32,
    flags: u32,
}

type Dispatcher = unsafe extern "C" fn(u32, *const Parameters) -> i32;

#[link(name = "kernel32")]
extern "system" {
    fn LoadLibraryExW(name: *const u16, file: *mut c_void, flags: u32) -> *mut c_void;
    fn GetProcAddress(module: *mut c_void, name: *const u8) -> *mut c_void;
    fn FreeLibrary(module: *mut c_void) -> i32;
}

struct Library(*mut c_void);
impl Drop for Library {
    fn drop(&mut self) { unsafe { FreeLibrary(self.0); } }
}

fn request_payload(operation: u32) -> Option<Vec<u8>> {
    if !matches!(operation, INITIALIZE | IS_PROVISIONED | FINALIZE) { return None; }
    let mut bytes = Vec::with_capacity(16);
    bytes.extend_from_slice(&1u32.to_be_bytes()); // Clear, not encrypted framing.
    bytes.extend_from_slice(&1u32.to_be_bytes()); // Protocol marker.
    if operation == IS_PROVISIONED {
        bytes.extend_from_slice(&(-2i64).to_be_bytes()); // Machine slot, not a user DSID.
    }
    Some(bytes)
}

fn call(dispatch: Dispatcher, operation: u32) -> Result<i32, i32> {
    let mut bytes = request_payload(operation).expect("readiness operation allowlist");
    let mut parameters = Parameters {
        payload: bytes.as_mut_ptr(), input_size: bytes.len() as u32,
        output_size: 4, flags: 0,
    };
    let transport = unsafe { dispatch(operation, &mut parameters) };
    println!("windows_adi_dispatch={operation:08x}; status={transport}");
    if transport < 0 { return Err(transport); }
    Ok(i32::from_be_bytes(bytes[..4].try_into().unwrap()))
}

fn initialized_or_finalized(result: &Result<i32, i32>) -> bool {
    // Match CoreADIADIProxy initialize/finalize: only negative results fail.
    // Machine-slot readiness below has a different, exact-value contract.
    matches!(result, Ok(code) if *code >= 0)
}

fn machine_readiness(result: Result<i32, i32>) -> Result<bool, &'static str> {
    match result {
        Ok(0) => Ok(true),
        Ok(-45061) | Err(-45061) => Ok(false),
        _ => Err("machine readiness query failed"),
    }
}

fn run() -> Result<(), &'static str> {
    if std::env::args_os().len() != 2 { return Err("one verified library path required"); }
    let path = PathBuf::from(std::env::args_os().nth(1).unwrap())
        .canonicalize().map_err(|_| "library path unavailable")?;
    let wide: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // Search only the selected DLL directory plus system/application defaults.
    let module = unsafe { LoadLibraryExW(wide.as_ptr(), std::ptr::null_mut(), 0x100 | 0x1000) };
    if module.is_null() {
        println!("windows_adi_load_error={}", std::io::Error::last_os_error().raw_os_error().unwrap_or(-1));
        return Err("library loading failed");
    }
    let library = Library(module);
    let symbol = unsafe { GetProcAddress(library.0, b"vdfut768ig\0".as_ptr()) };
    if symbol.is_null() { return Err("dispatcher export unavailable"); }
    let dispatch: Dispatcher = unsafe { std::mem::transmute(symbol) };
    println!("windows_adi_library_loaded=true");
    let initialized = call(dispatch, INITIALIZE);
    println!("windows_adi_initialize={initialized:?}");
    if !initialized_or_finalized(&initialized) { return Err("initialization not successful"); }
    let provisioned = call(dispatch, IS_PROVISIONED);
    println!("windows_adi_machine_slot={provisioned:?}");
    let finalized = call(dispatch, FINALIZE);
    println!("windows_adi_finalize={finalized:?}");
    if !initialized_or_finalized(&finalized) { return Err("finalization not successful"); }
    match machine_readiness(provisioned)? {
        true => println!("windows_adi_readiness=provisioned"),
        false => println!("windows_adi_readiness=not-provisioned"),
    }
    Ok(())
}

fn main() -> std::process::ExitCode {
    match run() {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(reason) => { eprintln!("windows_adi_readiness_error={reason}"); std::process::ExitCode::from(1) }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn initialization_and_finalization_follow_nonnegative_status_contract() {
        assert!(initialized_or_finalized(&Ok(0)));
        assert!(initialized_or_finalized(&Ok(1)));
        assert!(!initialized_or_finalized(&Ok(-1)));
        assert!(!initialized_or_finalized(&Err(0)));
        assert!(!initialized_or_finalized(&Err(-1)));
    }
    #[test]
    fn readiness_does_not_treat_positive_status_as_provisioning_success() {
        assert_eq!(machine_readiness(Ok(0)), Ok(true));
        assert_eq!(machine_readiness(Ok(-45061)), Ok(false));
        assert_eq!(machine_readiness(Err(-45061)), Ok(false));
        assert!(machine_readiness(Ok(1)).is_err());
        assert!(machine_readiness(Err(-1)).is_err());
    }
    #[test]
    fn permits_only_three_readiness_operations() {
        assert!(request_payload(0).is_none());
        assert!(request_payload(0x72096fe6).is_none()); // Account enumeration is excluded.
        assert!(request_payload(INITIALIZE).is_some());
        assert!(request_payload(IS_PROVISIONED).is_some());
        assert!(request_payload(FINALIZE).is_some());
    }
    #[test]
    fn initialization_and_teardown_use_exact_clear_framing() {
        assert_eq!(request_payload(INITIALIZE).unwrap(), [0, 0, 0, 1, 0, 0, 0, 1]);
        assert_eq!(request_payload(FINALIZE), request_payload(INITIALIZE));
    }
    #[test]
    fn readiness_queries_only_machine_slot_minus_two() {
        let payload = request_payload(IS_PROVISIONED).unwrap();
        assert_eq!(payload.len(), 16);
        assert_eq!(&payload[8..], &(-2i64).to_be_bytes());
    }
    #[test]
    fn parameter_abi_has_the_x64_c_layout() {
        assert_eq!(std::mem::size_of::<Parameters>(), 24);
        assert_eq!(std::mem::offset_of!(Parameters, input_size), 8);
        assert_eq!(std::mem::offset_of!(Parameters, flags), 16);
    }
}
