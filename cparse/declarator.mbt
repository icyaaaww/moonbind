//! Declarators.
//!
//! A C declarator is read from the name outwards: in `int (*a[3])[4]`, `a` is
//! an array of three pointers to arrays of four ints. Wrapping the specifier
//! type in the wrong order is the classic way to get `*a[3]` wrong, so
//! instead of applying constructors while parsing, a declarator is reduced to
//! an ordered chain of constructors running from the name outwards. The chain
//! is then folded from its far end towards the name:
//!
//! ```text
//! int *a[3]      chain: [CArr 3, CPtr]        fold: Arr 3 (Ptr T)
//! int (*a)[3]    chain: [CPtr, CArr 3]        fold: Ptr (Arr 3 T)
//! ```
//!
//! Keeping the chain also preserves where the name sits, which is what makes
//! the return type of `void (*signal(int, void (*)(int)))(int)` recoverable:
//! the function that `signal` names is always `chain[0]`, and its return type
//! is the fold of the remainder.

///|
/// | One step of a declarator: pointer, array of N, or function.
enum Ctor {
  CPtr
  CArr(Int64)
  CFn(Array[@ast.CParam], Bool)
}

///|
/// | A parsed declarator.
struct Declarator {
  /// The declared identifier. Empty for abstract declarators, which appear
  /// in casts, `sizeof` expressions and parameter lists.
  name : String
  /// Constructors from the name outwards; `chain[0]` is closest to the name.
  chain : Array[Ctor]
}

///|
/// | Wrap `t` in one constructor.
fn apply_ctor(c : Ctor, t : @ast.CType) -> @ast.CType {
  match c {
    CPtr => @ast.Pointer(t)
    CArr(n) => @ast.Array(t, n)
    CFn(params, variadic) =>
      @ast.Fn({ ret: t, params: params.map(p => p.ty), variadic, })
  }
}

///|
/// | The type a declarator declares, given the type from its specifiers.
fn Declarator::type_of(self : Declarator, base : @ast.CType) -> @ast.CType {
  let mut t = base
  let mut i = self.chain.length() - 1
  while i >= 0 {
    t = apply_ctor(self.chain[i], t)
    i = i - 1
  }
  t
}

///|
/// | If this declarator names a function, its parameter list and variadic
/// flag. Only `chain[0]` can be the function the name binds to: constructors
/// farther out describe the return type.
fn Declarator::fn_signature(self : Declarator) -> (Array[@ast.CParam], Bool)? {
  if self.chain.length() == 0 {
    return None
  }
  match self.chain[0] {
    CFn(params, variadic) => Some((params, variadic))
    _ => None
  }
}

///|
/// | The return type of a function declarator: the same fold as `type_of`
/// with the function constructor at the name skipped.
fn Declarator::ret_of(self : Declarator, base : @ast.CType) -> @ast.CType {
  let mut t = base
  let mut i = self.chain.length() - 1
  while i >= 1 {
    t = apply_ctor(self.chain[i], t)
    i = i - 1
  }
  t
}

///|
/// | Parse one declarator. Attributes may appear before and after it; they
/// are consumed here and attached by the caller.
fn Cursor::parse_declarator(self : Cursor) -> Declarator {
  let leading = Attrs::new()
  self.skip_attributes(leading)
  let mut ptrs = 0
  while self.at("*") {
    let _ = self.next()
    ptrs = ptrs + 1
    self.skip_type_qualifiers()
    let junk = Attrs::new()
    self.skip_attributes(junk)
  }
  let (name, chain) = self.parse_direct_declarator()
  for _ in 0..<ptrs {
    chain.push(CPtr)
  }
  let trailing = Attrs::new()
  self.skip_attributes(trailing)
  { name, chain, }
}

///|
/// | The direct declarator: the name or a parenthesised declarator, followed
/// by array and parameter suffixes.
fn Cursor::parse_direct_declarator(self : Cursor) -> (String, Array[Ctor]) {
  let chain : Array[Ctor] = []
  let mut name = ""
  if self.at("(") && self.starts_grouped_declarator() {
    let _ = self.next()
    let inner = self.parse_declarator()
    if !self.accept(")") {
      self.diagnose(
        self.peek(),
        "unclosed_declarator",
        "expected closing parenthesis",
      )
    }
    name = inner.name
    chain.append(inner.chain)
  } else if self.peek().kind == @lex.Ident {
    name = self.next().text
  }
  while !self.at_end() {
    if self.at("[") {
      let inner = self.take_balanced("[", "]")
      chain.push(CArr(self.array_length(inner)))
      continue
    }
    if self.at("(") && !self.starts_grouped_declarator() {
      let (params, variadic) = self.parse_param_list()
      chain.push(CFn(params, variadic))
      continue
    }
    break
  }
  (name, chain)
}

///|
/// | Decide whether a `(` opens a parenthesised declarator or a parameter
/// list. `int (*f)(void)` and `int (f)(void)` both group, while
/// `int f(void)` and `int f()` do not; the only real ambiguity is a lone
/// identifier, which groups unless it names a type.
fn Cursor::starts_grouped_declarator(self : Cursor) -> Bool {
  let t1 = self.peek_at(1)
  if t1.kind == @lex.Punct {
    return t1.text == "*" || t1.text == "("
  }
  if t1.kind == @lex.Ident {
    return !self.is_type_name(t1.text)
  }
  false
}

///|
/// | True when `name` is a keyword or a typedef name, and therefore starts a
/// parameter list rather than identifying a declarator. Qualifiers and
/// storage classes count: `const char *fmt` opens a parameter, not a
/// parenthesised declarator.
fn Cursor::is_type_name(self : Cursor, name : String) -> Bool {
  if is_type_keyword(name) || is_declaration_noise(name) {
    return true
  }
  self.module.typedefs.contains(name)
}

///|
/// | Array bound. A missing bound is a flexible array member or an
/// unspecified parameter dimension; both are recorded as zero, which the
/// layout pass treats as "no storage of its own".
fn Cursor::array_length(self : Cursor, toks : Array[@lex.Token]) -> Int64 {
  let kept = toks.filter(t => {
    t.text != "static" && t.text != "restrict" && t.text != "__restrict"
  })
  match self.eval_const(kept) {
    Some(v) => if v < 0L { 0L } else { v }
    None => 0L
  }
}

///|
/// | Parse a parameter list, leaving the cursor after the closing `)`.
fn Cursor::parse_param_list(self : Cursor) -> (Array[@ast.CParam], Bool) {
  let params : Array[@ast.CParam] = []
  let mut variadic = false
  let _ = self.accept("(")
  if self.accept(")") {
    return (params, variadic)
  }
  // `f(void)` declares a function of no parameters, not one parameter of
  // type void.
  if self.at("void") && self.peek_at(1).text == ")" {
    let _ = self.next()
    let _ = self.next()
    return (params, variadic)
  }
  while !self.at_end() && !self.at(")") {
    if self.accept("...") {
      variadic = true
      break
    }
    let specs = Specs::new()
    let attrs = Attrs::new()
    self.parse_specs(specs, attrs)
    if specs.base == BUnset &&
      specs.tag is None &&
      specs.named is None &&
      specs.signed is None &&
      specs.short == 0 &&
      specs.long == 0 {
      self.diagnose(
        self.peek(),
        "unknown_parameter_type",
        "parameter type is missing or unsupported",
      )
    }
    if self.at(")") || self.at(",") {
      // A prototype that gives only the type, as in `void f(int, char)`.
      params.push(@ast.CParam::{ name: "", ty: specs.resolve(self.platform), })
    } else {
      let d = self.parse_declarator()
      params.push(@ast.CParam::{
        name: d.name,
        ty: d.type_of(specs.resolve(self.platform)),
      })
    }
    let junk = Attrs::new()
    self.skip_attributes(junk)
    if !self.accept(",") {
      break
    }
  }
  if !self.accept(")") {
    self.diagnose(
      self.peek(),
      "unclosed_parameters",
      "expected closing parenthesis",
    )
  }
  (params, variadic)
}

///|
/// | Function parameters of array or function type are adjusted to pointers
/// (C11 6.7.6.3p7). Doing it here keeps the layout pass from seeing an array
/// where the ABI passes a pointer.
fn decay_params(params : Array[@ast.CParam]) -> Array[@ast.CParam] {
  params.map(fn(p) {
    let ty = match p.ty {
      @ast.Array(inner, _) => @ast.Pointer(inner)
      @ast.Fn(sig) => @ast.Pointer(@ast.Fn(sig))
      other => other
    }
    @ast.CParam::{ name: p.name, ty, }
  })
}

///|
/// | Evaluate a constant expression. Enumerators and earlier `#define`s are
/// visible through `env`; anything else evaluates to zero the way an unknown
/// identifier does in `#if`.
fn Cursor::eval_const(self : Cursor, toks : Array[@lex.Token]) -> Int64? {
  if toks.length() == 0 {
    return None
  }
  let macros : Map[String, @cp.Macro] = Map([])
  let env = self.env
  @cp.evaluate_with(toks, macros, self.platform, fn(n) { env.get(n) })
}
