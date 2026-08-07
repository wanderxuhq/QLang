/*!
 * QLang environment (scope) module
 *
 * This module manages variable bindings and scopes in QLang programs.
 * Environment uses lexical scoping and supports closures.
 */

use std::rc::Rc;
use std::cell::RefCell;
use std::collections::HashMap;
use crate::value::{Value, RuntimeError};

/// Reference-counted environment pointer
///
/// Uses a combination of Rc<RefCell<Environment>>:
/// - Rc: provides shared ownership; multiple scopes can reference the same parent environment
/// - RefCell: provides interior mutability, allowing the environment to be modified through an immutable reference
///
/// # Scope chain
///
/// When looking up a variable, the scope chain is traversed upward:
/// ```text
/// global environment
///   └── function A's environment
///         └── function B's environment (function B is defined inside function A)
/// ```
/// Function B can access variables defined in function A's and the global environment.
pub type EnvRef = Rc<RefCell<Environment>>;

/// Variable lookup result: distinguishes the three states undefined / uninitialized / value.
#[derive(Debug)]
pub enum Lookup {
    Undefined,
    Uninitialized,
    Value(Value),
}

/// Create a new root environment
///
/// Used to initialize the interpreter's global environment.
/// The root environment has no parent.
pub fn new_env() -> EnvRef {
    Rc::new(RefCell::new(Environment::new()))
}

/// Create a child environment
///
/// Used to create the local scope for function calls.
/// A child environment inherits its parent's scope chain.
///
/// # Examples
///
/// ```qlang
/// let x = 10;  // global environment
/// let foo = () -> {
///     let x = 20;  // foo's local environment
///     println(x);  // prints 20
/// };
/// ```
pub fn child_env(parent: &EnvRef) -> EnvRef {
    Rc::new(RefCell::new(Environment::with_parent(Rc::clone(parent))))
}

/// Variable binding: a value plus an optional type annotation ((evaluated type value, source text)).
///
/// `value: None` means uninitialized (declared but not assigned).
#[derive(Debug)]
pub struct Binding {
    pub value: Option<Value>, // None = uninitialized (declared but not assigned)
    pub annotation: Option<(Value, String)>,
}

/// Environment (scope)
///
/// An environment stores the mapping from variable names to values.
/// Each environment may have a parent environment, forming a scope chain.
///
/// # Core operations
///
/// 1. **define** - defines a new variable
/// 2. **get** - fetches a variable value (searching along the scope chain)
/// 3. **assign** - modifies a variable value (searching along the scope chain)
/// 4. **contains** - checks whether a variable exists
///
/// # Lexical scoping
///
/// QLang uses lexical scoping (static scoping):
/// - a variable's scope is determined at definition time, not at call time
/// - closures capture the environment at definition time
///
/// # Examples
///
/// ```qlang
/// let makeCounter = () -> {
///     let count = 0;
///     return () -> {
///         count = count + 1;
///         return count;
///     };
/// };
///
/// let counter1 = makeCounter();
/// let counter2 = makeCounter();
///
/// println(counter1());  // 1
/// println(counter1());  // 2
/// println(counter2());  // 1 (a different closure environment)
/// ```
#[derive(Debug)]
pub struct Environment {
    /// Variable bindings of the current scope
    values: HashMap<String, Binding>,
    /// Parent environment, used for scope chain lookups
    parent: Option<EnvRef>,
}

impl Environment {
    /// Create a new root environment
    ///
    /// The root environment has no parent; it is the end of the scope chain.
    pub fn new() -> Self {
        Environment {
            values: HashMap::new(),
            parent: None,
        }
    }

    /// Create a child environment with a parent
    ///
    /// A child environment inherits its parent's scope.
    /// When a variable is not found in the child environment, the parent is searched next.
    ///
    /// # Arguments
    ///
    /// - `parent` - the parent environment reference
    pub fn with_parent(parent: EnvRef) -> Self {
        Environment {
            values: HashMap::new(),
            parent: Some(parent),
        }
    }

    /// Define a new variable
    ///
    /// Creates a new variable binding in the current scope.
    /// If the variable already exists, the old value is overwritten.
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::environment::Environment;
    /// use qlang::value::Value;
    ///
    /// let mut env = Environment::new();
    /// env.define("x".to_string(), Value::Number(10.0));
    /// ```
    pub fn define(&mut self, name: String, value: Value) {
        self.values.insert(name, Binding { value: Some(value), annotation: None });
    }

    /// Binding with an annotation (when the annotation is Some, reassignment is checked again).
    pub fn define_annotated(&mut self, name: String, value: Value, annotation: Option<(Value, String)>) {
        self.values.insert(name, Binding { value: Some(value), annotation });
    }

    /// Get a variable value
    ///
    /// Looks up the variable in the current scope and the parent scope chain.
    /// If found, returns a copy of the value.
    ///
    /// # Lookup order
    ///
    /// 1. Check the current scope
    /// 2. If not found, recursively check the parent environment
    /// 3. If not found all the way up to the root environment, return None
    ///
    /// # Uninitialized bindings
    ///
    /// A binding declared without a value (`let x;`, value is None) also returns
    /// None — `get` cannot distinguish it from an undefined variable. Use
    /// [`Environment::lookup`](Self::lookup) when the three states
    /// (undefined / uninitialized / value) must be told apart.
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::environment::Environment;
    /// use qlang::value::Value;
    ///
    /// let mut env = Environment::new();
    /// env.define("x".to_string(), Value::Number(10.0));
    /// let value = env.get("x");  // Some(Value::Number(10.0))
    /// let unknown = env.get("y");  // None
    /// ```
    pub fn get(&self, name: &str) -> Option<Value> {
        if let Some(b) = self.values.get(name) { b.value.clone() }
        else if let Some(ref parent) = self.parent { parent.borrow().get(name) }
        else { None }
    }

    /// Looks up a variable along the scope chain, distinguishing undefined / uninitialized / value.
    pub fn lookup(&self, name: &str) -> Lookup {
        if let Some(b) = self.values.get(name) {
            match &b.value {
                Some(v) => Lookup::Value(v.clone()),
                None => Lookup::Uninitialized,
            }
        } else if let Some(ref parent) = self.parent { parent.borrow().lookup(name) }
        else { Lookup::Undefined }
    }

    /// Declare an uninitialized binding (declared but not assigned; value is None).
    pub fn define_uninitialized(&mut self, name: String, annotation: Option<(Value, String)>) {
        self.values.insert(name, Binding { value: None, annotation });
    }

    /// Looks up a variable's annotation along the scope chain (only used for reassignment checks).
    pub fn get_annotation(&self, name: &str) -> Option<(Value, String)> {
        if let Some(b) = self.values.get(name) { b.annotation.clone() }
        else if let Some(ref parent) = self.parent { parent.borrow().get_annotation(name) }
        else { None }
    }

    /// Modify a variable value
    ///
    /// Searches up the scope chain and modifies the variable's value.
    /// Only existing variables can be modified; new variables cannot be created.
    ///
    /// # Return value
    ///
    /// - Ok(()) - modification succeeded
    /// - Err(UndefinedVariable) - the variable does not exist
    ///
    /// # Example
    ///
    /// ```
    /// use qlang::environment::Environment;
    /// use qlang::value::Value;
    ///
    /// let mut env = Environment::new();
    /// env.define("x".to_string(), Value::Number(10.0));
    /// env.assign("x", Value::Number(20.0));  // Ok(())
    /// env.assign("y", Value::Number(30.0));  // Err(UndefinedVariable)
    /// ```
    pub fn assign(&mut self, name: &str, value: Value) -> Result<(), RuntimeError> {
        if let Some(b) = self.values.get_mut(name) {
            b.value = Some(value); // keeps annotation; this is how uninitialized bindings get initialized
            Ok(())
        } else if let Some(ref parent) = self.parent {
            parent.borrow_mut().assign(name, value)
        } else {
            Err(RuntimeError::UndefinedVariable(name.to_string()))
        }
    }

    /// Check whether a variable exists in the current scope
    ///
    /// Only checks the current scope; does not search up into the parent environment.
    pub fn contains(&self, name: &str) -> bool {
        self.values.contains_key(name)
    }

    /// Get a reference to the parent environment
    pub fn parent(&self) -> Option<&EnvRef> {
        self.parent.as_ref()
    }

    /// Get all bindings of the current scope (for debugging)
    pub fn bindings(&self) -> &HashMap<String, Binding> {
        &self.values
    }

    /// Get an iterator over all bindings
    pub fn iter_bindings(&self) -> impl Iterator<Item = (&String, &Binding)> {
        self.values.iter()
    }
}
