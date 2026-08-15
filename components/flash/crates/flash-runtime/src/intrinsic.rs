//! Shared metadata and execution for expression intrinsics.

use crate::Value;
use crate::module::ValueType;
use crate::operation::{self, OperationError};

/// A built-in callable that is resolved in expression position when no lexical
/// binding with the same name is visible.
#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub enum ExpressionIntrinsic {
    Int,
    Float,
}

impl ExpressionIntrinsic {
    /// Every expression intrinsic in deterministic name order.
    pub const ALL: [Self; 2] = [Self::Float, Self::Int];

    /// Resolves one exact intrinsic spelling.
    #[must_use]
    pub fn lookup(name: &str) -> Option<Self> {
        match name {
            "int" => Some(Self::Int),
            "float" => Some(Self::Float),
            _ => None,
        }
    }

    /// The exact language spelling.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Int => "int",
            Self::Float => "float",
        }
    }

    /// The single parameter name used by query and protocol surfaces.
    #[must_use]
    pub const fn parameter_name(self) -> &'static str {
        "value"
    }

    /// The number of arguments accepted by this intrinsic.
    #[must_use]
    pub const fn arity(self) -> usize {
        1
    }

    /// The statically known result family.
    #[must_use]
    pub const fn result_type(self) -> ValueType {
        match self {
            Self::Int => ValueType::Int,
            Self::Float => ValueType::Float,
        }
    }

    /// Whether one statically known input family is accepted.
    #[must_use]
    pub const fn accepts_type(self, value_type: &ValueType) -> bool {
        matches!(
            value_type,
            ValueType::Any | ValueType::Int | ValueType::Float
        )
    }

    /// The input-family text shared by static diagnostics and editor help.
    #[must_use]
    pub const fn parameter_type_label(self) -> &'static str {
        "Int | Float"
    }

    /// Concise language documentation for hover surfaces.
    #[must_use]
    pub const fn documentation(self) -> &'static str {
        match self {
            Self::Int => "Converts an Int or Float value to Int by truncating toward zero.",
            Self::Float => "Converts an Int or Float value to Float.",
        }
    }

    /// Applies the intrinsic to one already evaluated argument.
    pub fn invoke(self, value: &Value) -> Result<Value, OperationError> {
        match self {
            Self::Int => operation::to_int(value),
            Self::Float => operation::to_float(value),
        }
    }
}
