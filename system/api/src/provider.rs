//! `FlashOS` runtime identity provider and strict `/usr/lib/os-release` parsing.

#[cfg(target_os = "redox")]
use std::{
    fs::File,
    io::{self, Read},
};

use crate::contract::{Architecture, MAX_RELEASE_BYTES};

#[cfg(target_os = "redox")]
const OS_RELEASE_PATH: &str = "/usr/lib/os-release";
const MAX_OS_RELEASE_BYTES: usize = 64 * 1024;

/// Provider failures are mapped to the stable API error vocabulary.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProviderError {
    Unavailable,
    PermissionDenied,
    Cancelled,
    Internal,
}

/// The only system-owned information required by `system.describe`.
pub trait IdentityProvider {
    /// Return the bounded installed release identity.
    ///
    /// # Errors
    ///
    /// Returns a classified provider failure when identity cannot be supplied.
    fn release_identity(&self) -> Result<String, ProviderError>;

    /// Return an architecture from the schema 1 vocabulary.
    ///
    /// # Errors
    ///
    /// Returns a classified provider failure for an unsupported or unavailable target.
    fn architecture(&self) -> Result<Architecture, ProviderError>;
}

/// Reader injected into the installed provider for deterministic tests.
pub trait OsReleaseReader {
    /// Read a bounded installed `os-release` surface.
    ///
    /// # Errors
    ///
    /// Returns a classified provider failure when the surface cannot be read.
    fn read(&self) -> Result<Vec<u8>, ProviderError>;
}

/// Architecture source injected separately from filesystem identity.
pub trait ArchitectureProvider {
    /// Return the compiled target architecture.
    ///
    /// # Errors
    ///
    /// Returns a classified provider failure when the target is unsupported.
    fn architecture(&self) -> Result<Architecture, ProviderError>;
}

/// Strict installed identity provider.
pub struct InstalledIdentityProvider<R, A> {
    reader: R,
    architecture: A,
}

impl<R, A> InstalledIdentityProvider<R, A> {
    #[must_use]
    pub const fn new(reader: R, architecture: A) -> Self {
        Self {
            reader,
            architecture,
        }
    }
}

impl<R: OsReleaseReader, A: ArchitectureProvider> IdentityProvider
    for InstalledIdentityProvider<R, A>
{
    fn release_identity(&self) -> Result<String, ProviderError> {
        parse_release_identity(&self.reader.read()?)
    }

    fn architecture(&self) -> Result<Architecture, ProviderError> {
        self.architecture.architecture()
    }
}

/// Runtime provider used by the installed transport.
pub struct ProductionProvider;

impl IdentityProvider for ProductionProvider {
    fn release_identity(&self) -> Result<String, ProviderError> {
        #[cfg(target_os = "redox")]
        {
            return InstalledIdentityProvider::new(FileOsReleaseReader, CompiledArchitecture)
                .release_identity();
        }
        #[cfg(not(target_os = "redox"))]
        {
            // A host development OS must never be presented as FlashOS.
            Err(ProviderError::Unavailable)
        }
    }

    fn architecture(&self) -> Result<Architecture, ProviderError> {
        #[cfg(target_os = "redox")]
        {
            return CompiledArchitecture.architecture();
        }
        #[cfg(not(target_os = "redox"))]
        {
            Err(ProviderError::Unavailable)
        }
    }
}

#[cfg(target_os = "redox")]
struct FileOsReleaseReader;

#[cfg(target_os = "redox")]
impl OsReleaseReader for FileOsReleaseReader {
    fn read(&self) -> Result<Vec<u8>, ProviderError> {
        let file = File::open(OS_RELEASE_PATH).map_err(map_io_error)?;
        let limit = u64::try_from(MAX_OS_RELEASE_BYTES + 1).map_err(|_| ProviderError::Internal)?;
        let mut bytes = Vec::new();
        file.take(limit)
            .read_to_end(&mut bytes)
            .map_err(map_io_error)?;
        if bytes.len() > MAX_OS_RELEASE_BYTES {
            return Err(ProviderError::Unavailable);
        }
        Ok(bytes)
    }
}

#[cfg(any(target_os = "redox", test))]
struct CompiledArchitecture;

#[cfg(any(target_os = "redox", test))]
impl ArchitectureProvider for CompiledArchitecture {
    fn architecture(&self) -> Result<Architecture, ProviderError> {
        #[cfg(target_arch = "x86_64")]
        {
            Ok(Architecture::X86_64)
        }
        #[cfg(not(target_arch = "x86_64"))]
        {
            Err(ProviderError::Unavailable)
        }
    }
}

#[cfg(target_os = "redox")]
fn map_io_error(error: io::Error) -> ProviderError {
    match error.kind() {
        io::ErrorKind::PermissionDenied => ProviderError::PermissionDenied,
        io::ErrorKind::Interrupted => ProviderError::Cancelled,
        io::ErrorKind::NotFound | io::ErrorKind::InvalidData => ProviderError::Unavailable,
        _ => ProviderError::Internal,
    }
}

/// Extract exactly one bounded `VERSION_ID` from an injected os-release surface.
///
/// # Errors
///
/// Returns [`ProviderError::Unavailable`] when the input is oversized, non-UTF-8,
/// missing, duplicated, empty, or outside the safe release vocabulary.
pub fn parse_release_identity(bytes: &[u8]) -> Result<String, ProviderError> {
    if bytes.len() > MAX_OS_RELEASE_BYTES {
        return Err(ProviderError::Unavailable);
    }
    let document = std::str::from_utf8(bytes).map_err(|_| ProviderError::Unavailable)?;
    let mut selected = None;
    for line in document.lines() {
        let Some(raw) = line.strip_prefix("VERSION_ID=") else {
            continue;
        };
        if selected.is_some() {
            return Err(ProviderError::Unavailable);
        }
        selected = Some(parse_release_value(raw)?);
    }
    selected.ok_or(ProviderError::Unavailable)
}

fn parse_release_value(raw: &str) -> Result<String, ProviderError> {
    let value = match (raw.as_bytes().first(), raw.as_bytes().last()) {
        (Some(b'"'), Some(b'"')) | (Some(b'\''), Some(b'\'')) if raw.len() >= 2 => {
            &raw[1..raw.len() - 1]
        }
        _ => raw,
    };
    if value.is_empty()
        || value.len() > MAX_RELEASE_BYTES
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-'))
    {
        return Err(ProviderError::Unavailable);
    }
    Ok(value.to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Clone)]
    struct BytesReader(Result<Vec<u8>, ProviderError>);

    impl OsReleaseReader for BytesReader {
        fn read(&self) -> Result<Vec<u8>, ProviderError> {
            self.0.clone()
        }
    }

    struct FixedArchitecture(Result<Architecture, ProviderError>);

    impl ArchitectureProvider for FixedArchitecture {
        fn architecture(&self) -> Result<Architecture, ProviderError> {
            self.0
        }
    }

    #[test]
    fn installed_identity_uses_only_the_injected_surface() {
        let provider = InstalledIdentityProvider::new(
            BytesReader(Ok(b"NAME=FlashOS\nVERSION_ID=\"0.3.0\"\n".to_vec())),
            FixedArchitecture(Ok(Architecture::X86_64)),
        );
        assert_eq!(provider.release_identity().unwrap(), "0.3.0");
        assert_eq!(provider.architecture().unwrap(), Architecture::X86_64);
    }

    #[test]
    fn release_parser_rejects_missing_duplicate_non_utf8_empty_and_oversized_values() {
        let oversized = format!("VERSION_ID={}\n", "x".repeat(MAX_RELEASE_BYTES + 1));
        let cases: Vec<Vec<u8>> = vec![
            b"NAME=FlashOS\n".to_vec(),
            b"VERSION_ID=0.2.0\nVERSION_ID=0.3.0\n".to_vec(),
            vec![
                b'V', b'E', b'R', b'S', b'I', b'O', b'N', b'_', b'I', b'D', b'=', 0xff,
            ],
            b"VERSION_ID=\"\"\n".to_vec(),
            oversized.into_bytes(),
            b"VERSION_ID=unsafe value\n".to_vec(),
        ];
        for bytes in cases {
            assert_eq!(
                parse_release_identity(&bytes),
                Err(ProviderError::Unavailable)
            );
        }
    }

    #[test]
    fn reader_and_architecture_failures_are_preserved() {
        let reader_failure = InstalledIdentityProvider::new(
            BytesReader(Err(ProviderError::PermissionDenied)),
            FixedArchitecture(Ok(Architecture::X86_64)),
        );
        assert_eq!(
            reader_failure.release_identity(),
            Err(ProviderError::PermissionDenied)
        );

        let architecture_failure = InstalledIdentityProvider::new(
            BytesReader(Ok(b"VERSION_ID=0.3.0\n".to_vec())),
            FixedArchitecture(Err(ProviderError::Cancelled)),
        );
        assert_eq!(
            architecture_failure.architecture(),
            Err(ProviderError::Cancelled)
        );
    }

    #[test]
    fn production_provider_refuses_host_identity() {
        #[cfg(not(target_os = "redox"))]
        {
            assert_eq!(
                ProductionProvider.release_identity(),
                Err(ProviderError::Unavailable)
            );
            assert_eq!(
                ProductionProvider.architecture(),
                Err(ProviderError::Unavailable)
            );
        }
    }

    #[test]
    fn compiled_architecture_uses_only_the_target_configuration() {
        #[cfg(target_arch = "x86_64")]
        assert_eq!(
            CompiledArchitecture.architecture(),
            Ok(Architecture::X86_64)
        );
        #[cfg(not(target_arch = "x86_64"))]
        assert_eq!(
            CompiledArchitecture.architecture(),
            Err(ProviderError::Unavailable)
        );
    }
}
