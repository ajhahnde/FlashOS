//! Experimental, versioned `FlashOS` system semantics and their local adapter.

pub mod contract;
pub mod provider;
pub mod transport;

pub use contract::{
    ACTION_DESCRIBE, API_MATURITY, API_NAME, API_SCHEMA, ActionAvailability, ApiError,
    ApiErrorCode, ApiIdentity, ApiOutcome, Architecture, SystemDescription, SystemIdentity,
    describe_system,
};
pub use provider::{IdentityProvider, ProductionProvider, ProviderError};
