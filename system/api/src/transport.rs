//! Bounded single-shot command/JSON transport for the system contract.

use std::{ffi::OsString, io};

use serde::Serialize;

use crate::{
    ActionAvailability, ApiError, ApiErrorCode, ApiIdentity, ApiOutcome, Architecture,
    IdentityProvider, SystemDescription, SystemIdentity, describe_system,
};

/// Maximum complete standard-output response, including its trailing LF.
pub const MAX_OUTPUT_BYTES: usize = 64 * 1024;
/// Maximum complete human diagnostic written to standard error.
pub const MAX_DIAGNOSTIC_BYTES: usize = 4 * 1024;
/// Maximum bytes across the arguments after the executable.
pub const MAX_ARGUMENT_BYTES: usize = 4 * 1024;
/// Maximum arguments after the executable in schema 1.
pub const MAX_ARGUMENTS: usize = 5;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Action {
    Describe,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Request {
    pub action: Action,
    pub schema: u32,
}

#[derive(Debug, Eq, PartialEq)]
pub struct TransportResponse {
    pub stdout: Vec<u8>,
    pub exit_code: u8,
}

#[derive(Serialize)]
struct JsonApiIdentity<'a> {
    name: &'a str,
    schema: u32,
    maturity: &'a str,
}

#[derive(Serialize)]
struct JsonSystemIdentity<'a> {
    name: &'a str,
    release: &'a str,
    architecture: &'a str,
}

#[derive(Serialize)]
struct JsonActionAvailability<'a> {
    name: &'a str,
    kind: &'a str,
    available: bool,
}

#[derive(Serialize)]
struct JsonSystemDescription<'a> {
    action: &'a str,
    system: JsonSystemIdentity<'a>,
    actions: Vec<JsonActionAvailability<'a>>,
}

#[derive(Serialize)]
struct JsonError<'a> {
    code: &'a str,
    message: &'a str,
}

#[derive(Serialize)]
struct JsonSuccessEnvelope<'a> {
    api: JsonApiIdentity<'a>,
    result: JsonSystemDescription<'a>,
}

#[derive(Serialize)]
struct JsonErrorEnvelope<'a> {
    api: JsonApiIdentity<'a>,
    error: JsonError<'a>,
}

/// Parse only the closed schema 1 invocation.
///
/// # Errors
///
/// Returns a bounded semantic request error when arguments exceed their bounds,
/// are non-UTF-8, omit or repeat an option, or request an unsupported value.
pub fn parse_arguments(arguments: &[OsString]) -> Result<Request, ApiError> {
    if arguments.len() > MAX_ARGUMENTS || argument_bytes(arguments) > MAX_ARGUMENT_BYTES {
        return Err(ApiError::fixed(ApiErrorCode::InvalidRequest));
    }
    let values = arguments
        .iter()
        .map(|argument| argument.to_str())
        .collect::<Option<Vec<_>>>()
        .ok_or_else(|| ApiError::fixed(ApiErrorCode::InvalidRequest))?;
    let Some(action) = values.first() else {
        return Err(ApiError::fixed(ApiErrorCode::InvalidRequest));
    };
    if *action != "describe" {
        return Err(ApiError::fixed(ApiErrorCode::UnsupportedAction));
    }
    if values.len() != MAX_ARGUMENTS {
        return Err(ApiError::fixed(ApiErrorCode::InvalidRequest));
    }

    let mut schema = None;
    let mut format = None;
    for pair in values[1..].chunks_exact(2) {
        match pair[0] {
            "--schema" if schema.is_none() => schema = Some(pair[1]),
            "--format" if format.is_none() => format = Some(pair[1]),
            _ => return Err(ApiError::fixed(ApiErrorCode::InvalidRequest)),
        }
    }
    let schema = schema.ok_or_else(|| ApiError::fixed(ApiErrorCode::InvalidRequest))?;
    if schema != "1" {
        return Err(ApiError::fixed(ApiErrorCode::UnsupportedSchema));
    }
    if format != Some("json") {
        return Err(ApiError::fixed(ApiErrorCode::InvalidRequest));
    }
    Ok(Request {
        action: Action::Describe,
        schema: 1,
    })
}

/// Execute one request and produce exactly one bounded JSON envelope plus LF.
pub fn execute(arguments: &[OsString], provider: &impl IdentityProvider) -> TransportResponse {
    let outcome = match parse_arguments(arguments) {
        Ok(Request {
            action: Action::Describe,
            schema: 1,
        }) => describe_system(provider),
        Ok(_) => ApiOutcome::Error(ApiError::fixed(ApiErrorCode::Internal)),
        Err(error) => ApiOutcome::Error(error),
    };
    let exit_code = u8::from(matches!(outcome, ApiOutcome::Error(_)));
    match encode_outcome(&outcome) {
        Ok(stdout) => TransportResponse { stdout, exit_code },
        Err(()) => TransportResponse {
            stdout: encode_internal_fallback(),
            exit_code: 1,
        },
    }
}

fn argument_bytes(arguments: &[OsString]) -> usize {
    arguments.iter().fold(0usize, |total, argument| {
        total.saturating_add(argument.as_encoded_bytes().len())
    })
}

fn api_json(identity: &ApiIdentity) -> JsonApiIdentity<'_> {
    JsonApiIdentity {
        name: identity.name,
        schema: identity.schema,
        maturity: identity.maturity,
    }
}

fn system_json(identity: &SystemIdentity) -> JsonSystemIdentity<'_> {
    JsonSystemIdentity {
        name: identity.name,
        release: &identity.release,
        architecture: match identity.architecture {
            Architecture::X86_64 => Architecture::X86_64.as_str(),
        },
    }
}

fn action_json(action: &ActionAvailability) -> JsonActionAvailability<'_> {
    JsonActionAvailability {
        name: action.name,
        kind: action.kind,
        available: action.available,
    }
}

fn description_json(description: &SystemDescription) -> JsonSystemDescription<'_> {
    JsonSystemDescription {
        action: description.action,
        system: system_json(&description.system),
        actions: description.actions.iter().map(action_json).collect(),
    }
}

fn encode_outcome(outcome: &ApiOutcome) -> Result<Vec<u8>, ()> {
    let identity = ApiIdentity::schema_one();
    let mut bytes = match outcome {
        ApiOutcome::Success(description) => serde_json::to_vec(&JsonSuccessEnvelope {
            api: api_json(&identity),
            result: description_json(description),
        }),
        ApiOutcome::Error(error) => serde_json::to_vec(&JsonErrorEnvelope {
            api: api_json(&identity),
            error: JsonError {
                code: error.code.as_str(),
                message: &error.message,
            },
        }),
    }
    .map_err(|_| ())?;
    bytes.push(b'\n');
    if bytes.len() > MAX_OUTPUT_BYTES {
        return Err(());
    }
    Ok(bytes)
}

fn encode_internal_fallback() -> Vec<u8> {
    let fallback = b"{\"api\":{\"name\":\"flashos.system\",\"schema\":1,\"maturity\":\"experimental\"},\"error\":{\"code\":\"internal\",\"message\":\"system description failed internally\"}}\n";
    fallback.to_vec()
}

/// Emit a fixed, bounded diagnostic when the JSON transport itself cannot be written.
pub fn write_transport_diagnostic(mut writer: impl io::Write) {
    const DIAGNOSTIC: &[u8] = b"flashos-system: cannot write the API envelope\n";
    debug_assert!(DIAGNOSTIC.len() <= MAX_DIAGNOSTIC_BYTES);
    let _ = writer.write_all(DIAGNOSTIC);
}

#[cfg(test)]
mod tests {
    use std::ffi::OsStr;

    use super::*;
    use crate::{Architecture, ProviderError};

    struct FakeProvider(Result<String, ProviderError>);

    impl IdentityProvider for FakeProvider {
        fn release_identity(&self) -> Result<String, ProviderError> {
            self.0.clone()
        }

        fn architecture(&self) -> Result<Architecture, ProviderError> {
            Ok(Architecture::X86_64)
        }
    }

    fn arguments(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    fn json(response: &TransportResponse) -> serde_json::Value {
        serde_json::from_slice(&response.stdout).expect("response should be JSON")
    }

    #[test]
    fn success_encoding_is_deterministic_exclusive_and_lf_terminated() {
        let response = execute(
            &arguments(&["describe", "--schema", "1", "--format", "json"]),
            &FakeProvider(Ok("0.3.0".to_owned())),
        );
        assert_eq!(response.exit_code, 0);
        assert_eq!(
            String::from_utf8(response.stdout.clone()).unwrap(),
            "{\"api\":{\"name\":\"flashos.system\",\"schema\":1,\"maturity\":\"experimental\"},\"result\":{\"action\":\"system.describe\",\"system\":{\"name\":\"FlashOS\",\"release\":\"0.3.0\",\"architecture\":\"x86_64\"},\"actions\":[{\"name\":\"system.describe\",\"kind\":\"query\",\"available\":true}]}}\n"
        );
        assert!(response.stdout.len() <= MAX_OUTPUT_BYTES);
        assert_eq!(response.stdout.last(), Some(&b'\n'));
        assert!(json(&response).get("error").is_none());
    }

    #[test]
    fn semantic_error_encoding_is_exclusive_and_uses_exit_one() {
        let response = execute(
            &arguments(&["describe", "--schema", "1", "--format", "json"]),
            &FakeProvider(Err(ProviderError::PermissionDenied)),
        );
        assert_eq!(response.exit_code, 1);
        let document = json(&response);
        assert_eq!(document["error"]["code"], "permission_denied");
        assert!(document.get("result").is_none());
    }

    #[test]
    fn argument_contract_fails_closed() {
        let cases = [
            (vec![], "invalid_request"),
            (
                vec!["inspect", "--schema", "1", "--format", "json"],
                "unsupported_action",
            ),
            (
                vec!["describe", "--schema", "2", "--format", "json"],
                "unsupported_schema",
            ),
            (vec!["describe", "--schema", "1"], "invalid_request"),
            (
                vec!["describe", "--schema", "1", "--schema", "1"],
                "invalid_request",
            ),
            (
                vec!["describe", "--schema", "1", "--format", "text"],
                "invalid_request",
            ),
            (
                vec!["describe", "--schema", "1", "--format", "json", "extra"],
                "invalid_request",
            ),
        ];
        for (case, expected_code) in cases {
            let response = execute(&arguments(&case), &FakeProvider(Ok("0.3.0".to_owned())));
            assert_eq!(response.exit_code, 1, "case {case:?}");
            assert_eq!(
                json(&response)["error"]["code"],
                expected_code,
                "case {case:?}"
            );
        }
    }

    #[test]
    fn options_may_be_explicit_in_either_order() {
        let response = execute(
            &arguments(&["describe", "--format", "json", "--schema", "1"]),
            &FakeProvider(Ok("0.3.0".to_owned())),
        );
        assert_eq!(response.exit_code, 0);
    }

    #[test]
    fn argument_byte_bound_is_enforced_without_echoing_input() {
        let huge = "x".repeat(MAX_ARGUMENT_BYTES + 1);
        let response = execute(
            &[OsString::from("describe"), OsString::from(huge)],
            &FakeProvider(Ok("0.3.0".to_owned())),
        );
        assert_eq!(json(&response)["error"]["code"], "invalid_request");
        assert!(!String::from_utf8_lossy(&response.stdout).contains(&"x".repeat(32)));
    }

    #[cfg(unix)]
    #[test]
    fn non_utf8_arguments_are_invalid_requests() {
        use std::os::unix::ffi::OsStrExt;

        let response = execute(
            &[
                OsString::from("describe"),
                OsString::from("--schema"),
                OsStr::from_bytes(&[0xff]).to_owned(),
                OsString::from("--format"),
                OsString::from("json"),
            ],
            &FakeProvider(Ok("0.3.0".to_owned())),
        );
        assert_eq!(json(&response)["error"]["code"], "invalid_request");
    }

    #[test]
    fn every_closed_error_code_has_a_json_spelling() {
        let codes = [
            (ApiErrorCode::InvalidRequest, "invalid_request"),
            (ApiErrorCode::UnsupportedSchema, "unsupported_schema"),
            (ApiErrorCode::UnsupportedAction, "unsupported_action"),
            (ApiErrorCode::Unavailable, "unavailable"),
            (ApiErrorCode::PermissionDenied, "permission_denied"),
            (ApiErrorCode::Cancelled, "cancelled"),
            (ApiErrorCode::Internal, "internal"),
        ];
        for (code, spelling) in codes {
            let bytes = encode_outcome(&ApiOutcome::Error(ApiError::fixed(code))).unwrap();
            let document: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
            assert_eq!(document["error"]["code"], spelling);
        }
    }
}
