//! The command registry and its minimal command signature.
//!
//! A [`CommandSignature`] is, for v0.1, exactly the pipeline-carrier contract an
//! internal command declares: the input carriers it accepts and the carrier it
//! produces. Typed parameters, flags, and options are a later additive extension
//! and are deliberately absent. A [`CommandRegistry`] maps a name to a signature;
//! it is empty by default, and each built-in's signature is registered with the
//! built-in. Registering a name twice is rejected, since a duplicate built-in name
//! is a definition-time bug rather than a runtime override.

use std::collections::{BTreeMap, BTreeSet};

/// One pipeline-edge carrier.
///
/// `Empty`, `ByteStream`, `Value`, and `ValueStream` are distinct payload states
/// that the planner never substitutes for one another.
#[derive(Clone, Copy, Debug, Eq, Hash, Ord, PartialEq, PartialOrd)]
pub enum Carrier {
    /// No payload, distinct from `null` and from an empty stream.
    Empty,
    /// One ordered logical sequence of bytes in arbitrary chunks.
    ByteStream,
    /// Exactly one runtime value.
    Value,
    /// An ordered sequence of zero or more runtime values.
    ValueStream,
}

/// An internal command's v0.1 signature: its name and pipeline-carrier contract.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CommandSignature {
    name: String,
    inputs: BTreeSet<Carrier>,
    output: Carrier,
}

impl CommandSignature {
    /// Builds a signature from a name, the input carriers it accepts, and the
    /// carrier it produces. Duplicate input carriers collapse to one.
    pub fn new(
        name: impl Into<String>,
        inputs: impl IntoIterator<Item = Carrier>,
        output: Carrier,
    ) -> Self {
        Self {
            name: name.into(),
            inputs: inputs.into_iter().collect(),
            output,
        }
    }

    /// The command name.
    #[must_use]
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Whether the command accepts `carrier` as input.
    #[must_use]
    pub fn accepts(&self, carrier: Carrier) -> bool {
        self.inputs.contains(&carrier)
    }

    /// The accepted input carriers, in a deterministic order.
    pub fn inputs(&self) -> impl Iterator<Item = Carrier> + '_ {
        self.inputs.iter().copied()
    }

    /// The carrier the command produces.
    #[must_use]
    pub fn output(&self) -> Carrier {
        self.output
    }
}

/// A map from a command name to its signature. Empty by default.
#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct CommandRegistry {
    commands: BTreeMap<String, CommandSignature>,
}

impl CommandRegistry {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// Registers `signature` under its name. Returns `true` if it was inserted, or
    /// `false` if a command of that name already exists, in which case the earlier
    /// signature is kept unchanged.
    pub fn register(&mut self, signature: CommandSignature) -> bool {
        if self.commands.contains_key(signature.name()) {
            return false;
        }
        self.commands.insert(signature.name.clone(), signature);
        true
    }

    /// The signature registered under `name`, if any.
    #[must_use]
    pub fn lookup(&self, name: &str) -> Option<&CommandSignature> {
        self.commands.get(name)
    }

    /// Whether a command of `name` is registered.
    #[must_use]
    pub fn contains(&self, name: &str) -> bool {
        self.commands.contains_key(name)
    }

    /// The number of registered commands.
    #[must_use]
    pub fn len(&self) -> usize {
        self.commands.len()
    }

    /// Whether the registry has no commands.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.commands.is_empty()
    }

    /// The registered command names, in sorted order.
    pub fn names(&self) -> impl Iterator<Item = &str> {
        self.commands.keys().map(String::as_str)
    }
}
