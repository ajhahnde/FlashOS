//! Transport-independent contract for the experimental `FlashOS` system API.

use crate::provider::{IdentityProvider, ProviderError};

/// The semantic contract identifier.
pub const API_NAME: &str = "flashos.system";
/// The first decodable contract shape.
pub const API_SCHEMA: u32 = 1;
/// Schema 1 is deliberately experimental.
pub const API_MATURITY: &str = "experimental";
/// The only action in schema 1.
pub const ACTION_DESCRIBE: &str = "system.describe";
/// The only product name accepted by schema 1.
pub const SYSTEM_NAME: &str = "FlashOS";
/// Maximum encoded release identity length.
pub const MAX_RELEASE_BYTES: usize = 128;
/// Maximum encoded semantic error-message length.
pub const MAX_ERROR_MESSAGE_BYTES: usize = 512;

/// Identity included in every schema 1 envelope.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApiIdentity {
    pub name: &'static str,
    pub schema: u32,
    pub maturity: &'static str,
}

impl ApiIdentity {
    #[must_use]
    pub const fn schema_one() -> Self {
        Self {
            name: API_NAME,
            schema: API_SCHEMA,
            maturity: API_MATURITY,
        }
    }
}

/// Architecture values defined by schema 1.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Architecture {
    X86_64,
}

impl Architecture {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::X86_64 => "x86_64",
        }
    }
}

/// Product identity returned by `system.describe`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemIdentity {
    pub name: &'static str,
    pub release: String,
    pub architecture: Architecture,
}

/// One action advertised by the running API instance.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ActionAvailability {
    pub name: &'static str,
    pub kind: &'static str,
    pub available: bool,
}

/// Schema 1 result for `system.describe`.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct SystemDescription {
    pub action: &'static str,
    pub system: SystemIdentity,
    pub actions: Vec<ActionAvailability>,
}

/// Stable semantic error categories in schema 1.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ApiErrorCode {
    InvalidRequest,
    UnsupportedSchema,
    UnsupportedAction,
    Unavailable,
    PermissionDenied,
    Cancelled,
    Internal,
}

impl ApiErrorCode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidRequest => "invalid_request",
            Self::UnsupportedSchema => "unsupported_schema",
            Self::UnsupportedAction => "unsupported_action",
            Self::Unavailable => "unavailable",
            Self::PermissionDenied => "permission_denied",
            Self::Cancelled => "cancelled",
            Self::Internal => "internal",
        }
    }
}

/// A bounded, safe semantic error.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct ApiError {
    pub code: ApiErrorCode,
    pub message: String,
}

impl ApiError {
    /// Construct an error only when its human message is safe for the transport.
    ///
    /// # Errors
    ///
    /// Returns a static reason when the message is empty, over the schema byte
    /// bound, or contains a terminal-control character.
    pub fn new(code: ApiErrorCode, message: &str) -> Result<Self, &'static str> {
        if message.is_empty() {
            return Err("error message must not be empty");
        }
        if message.len() > MAX_ERROR_MESSAGE_BYTES {
            return Err("error message exceeds the schema bound");
        }
        if message.chars().any(char::is_control) {
            return Err("error message contains a control character");
        }
        Ok(Self {
            code,
            message: message.to_owned(),
        })
    }

    #[must_use]
    pub fn fixed(code: ApiErrorCode) -> Self {
        let message = match code {
            ApiErrorCode::InvalidRequest => "the request is invalid",
            ApiErrorCode::UnsupportedSchema => "the requested schema is unsupported",
            ApiErrorCode::UnsupportedAction => "the requested action is unsupported",
            ApiErrorCode::Unavailable => "system description is unavailable",
            ApiErrorCode::PermissionDenied => "system description is not permitted",
            ApiErrorCode::Cancelled => "system description was cancelled",
            ApiErrorCode::Internal => "system description failed internally",
        };
        Self {
            code,
            message: message.to_owned(),
        }
    }
}

/// A transport-neutral success or semantic failure.
#[derive(Clone, Debug, Eq, PartialEq)]
pub enum ApiOutcome {
    Success(SystemDescription),
    Error(ApiError),
}

/// Evaluate the first bounded semantic action through an injected provider.
#[must_use]
pub fn describe_system(provider: &impl IdentityProvider) -> ApiOutcome {
    let release = match provider.release_identity() {
        Ok(release) => release,
        Err(error) => return ApiOutcome::Error(provider_error(error)),
    };
    let architecture = match provider.architecture() {
        Ok(architecture) => architecture,
        Err(error) => return ApiOutcome::Error(provider_error(error)),
    };

    ApiOutcome::Success(SystemDescription {
        action: ACTION_DESCRIBE,
        system: SystemIdentity {
            name: SYSTEM_NAME,
            release,
            architecture,
        },
        actions: vec![ActionAvailability {
            name: ACTION_DESCRIBE,
            kind: "query",
            available: true,
        }],
    })
}

fn provider_error(error: ProviderError) -> ApiError {
    let code = match error {
        ProviderError::Unavailable => ApiErrorCode::Unavailable,
        ProviderError::PermissionDenied => ApiErrorCode::PermissionDenied,
        ProviderError::Cancelled => ApiErrorCode::Cancelled,
        ProviderError::Internal => ApiErrorCode::Internal,
    };
    ApiError::fixed(code)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct FakeProvider(
        Result<String, ProviderError>,
        Result<Architecture, ProviderError>,
    );

    impl IdentityProvider for FakeProvider {
        fn release_identity(&self) -> Result<String, ProviderError> {
            self.0.clone()
        }

        fn architecture(&self) -> Result<Architecture, ProviderError> {
            self.1
        }
    }

    #[test]
    fn description_is_the_complete_schema_one_inventory() {
        let provider = FakeProvider(Ok("0.3.0".to_owned()), Ok(Architecture::X86_64));
        let ApiOutcome::Success(description) = describe_system(&provider) else {
            panic!("description should succeed");
        };
        assert_eq!(description.action, ACTION_DESCRIBE);
        assert_eq!(description.system.name, SYSTEM_NAME);
        assert_eq!(description.system.release, "0.3.0");
        assert_eq!(description.system.architecture, Architecture::X86_64);
        assert_eq!(
            description.actions,
            [ActionAvailability {
                name: ACTION_DESCRIBE,
                kind: "query",
                available: true,
            }]
        );
    }

    #[test]
    fn every_provider_failure_has_a_stable_semantic_code() {
        let cases = [
            (ProviderError::Unavailable, ApiErrorCode::Unavailable),
            (
                ProviderError::PermissionDenied,
                ApiErrorCode::PermissionDenied,
            ),
            (ProviderError::Cancelled, ApiErrorCode::Cancelled),
            (ProviderError::Internal, ApiErrorCode::Internal),
        ];
        for (provider_error, expected) in cases {
            let provider = FakeProvider(Err(provider_error), Ok(Architecture::X86_64));
            let ApiOutcome::Error(error) = describe_system(&provider) else {
                panic!("provider error should remain semantic");
            };
            assert_eq!(error.code, expected);
        }
    }

    #[test]
    fn error_messages_enforce_utf8_byte_and_control_bounds() {
        assert!(ApiError::new(ApiErrorCode::Internal, "safe message").is_ok());
        assert!(ApiError::new(ApiErrorCode::Internal, "").is_err());
        assert!(ApiError::new(ApiErrorCode::Internal, &"x".repeat(513)).is_err());
        assert!(ApiError::new(ApiErrorCode::Internal, "unsafe\nmessage").is_err());
    }
}
