//! Declaration-level structures: records, enums, typedefs, functions and
//! object-like constants. These mirror C's translation-unit-level namespace
//! and are what the parser fills in and the code generator consumes.

///|
/// | Whether a record is a `struct` or a `union`.
pub(all) enum RecordKind {
  Struct
  Union
} derive(Debug, Eq)

///|
/// | One member of a record.
pub(all) struct CField {
  pub name : String
  pub mut ty : CType
  /// Set for bitfields: the declared width in bits. A width of `0` is the
  /// anonymous zero-width padding bitfield and never contributes a member.
  pub bit_width : Int32?
  /// Set when the member came from an anonymous struct/union body.
  pub anonymous : Bool
  /// `__attribute__((aligned(n)))` on the member, in bytes.
  pub align : Int32?
} derive(Debug)

///|
/// | A `struct` or `union` definition. `complete` is false for a tag that
/// has only been forward declared.
pub(all) struct CRecordDecl {
  pub tag : String
  pub kind : RecordKind
  pub fields : Array[CField]
  pub complete : Bool
  /// `#pragma pack(n)` or `__attribute__((packed))` in effect at the
  /// definition site; `None` means natural alignment.
  pub mut pack : Int32?
  /// `__attribute__((aligned(n)))` on the record, in bytes.
  pub mut align : Int32?
} derive(Debug)

///|
/// | One enumerator.
pub(all) struct CEnumItem {
  pub name : String
  pub value : Int64
} derive(Debug)

///|
/// | An `enum` definition. In C the underlying type is implementation
/// defined; `underlying` records the smallest integer type that holds every
/// enumerator, which is what both GCC and Clang use when `-fshort-enums` is
/// off.
pub(all) struct CEnumDecl {
  pub tag : String
  pub items : Array[CEnumItem]
  pub complete : Bool
} derive(Debug)

///|
/// | A `typedef` name bound to the type it aliases.
pub(all) struct CTypedef {
  pub name : String
  pub mut ty : CType
} derive(Debug)

///|
/// | One parameter of a function declaration. `name` is empty for
/// declarations that only give the type, which is legal in prototypes.
pub(all) struct CParam {
  pub name : String
  pub mut ty : CType
} derive(Debug)

///|
/// | A function declaration.
pub(all) struct CFnDecl {
  pub name : String
  pub mut ret : CType
  pub params : Array[CParam]
  pub variadic : Bool
  /// True for `static` declarations, which have internal linkage and are not
  /// callable from generated bindings.
  pub internal : Bool
} derive(Debug)

///|
/// | An object declared at file scope with a constant initializer, such as
/// `#define`-style `const int FOO = 1;` or an enum-like macro.
pub(all) struct CConstDecl {
  pub name : String
  pub ty : CType
  pub value : Int64
} derive(Debug)

///|
/// | Everything the parser learned from one translation unit.
pub(all) struct CModule {
  pub records : Map[String, CRecordDecl]
  pub enums : Map[String, CEnumDecl]
  pub typedefs : Map[String, CTypedef]
  pub functions : Array[CFnDecl]
  pub constants : Array[CConstDecl]
  /// Include paths that were actually read, in order, for diagnostics.
  pub sources : Array[String]
  pub diagnostics : Array[Diagnostic]
  pub static_definitions : Array[CFnDecl]
  pub function_locations : Map[String, Diagnostic]
} derive(Debug)

///|
/// | An empty module.
pub fn CModule::new() -> CModule {
  {
    records: Map([]),
    enums: Map([]),
    typedefs: Map([]),
    functions: [],
    constants: [],
    sources: [],
    diagnostics: [],
    static_definitions: [],
    function_locations: Map([]),
  }
}

///|
/// | Record a complete record definition, replacing any forward declaration.
pub fn CModule::define_record(self : CModule, decl : CRecordDecl) -> Unit {
  self.records[decl.tag] = decl
}

///|
/// | Forward declare a record tag unless it is already known.
pub fn CModule::forward_record(
  self : CModule,
  kind : RecordKind,
  tag : String,
) -> Unit {
  if !self.records.contains(tag) {
    self.records[tag] = {
      tag,
      kind,
      fields: [],
      complete: false,
      pack: None,
      align: None,
    }
  }
}

///|
/// | Give a record a new canonical tag. Used for the common
/// `typedef struct { ... } Name;` idiom: the anonymous record is parsed
/// under a synthetic tag and then adopted by the typedef name, so generated
/// bindings read as `Name` rather than `__anon_3`.
pub fn CModule::rename_record(
  self : CModule,
  old_tag : String,
  new_tag : String,
) -> Unit {
  match self.records.get(old_tag) {
    Some(rec) => {
      if self.records.contains(new_tag) {
        return
      }
      self.records.remove(old_tag)
      self.records[new_tag] = {
        tag: new_tag,
        kind: rec.kind,
        fields: rec.fields,
        complete: rec.complete,
        pack: rec.pack,
        align: rec.align,
      }
    }
    None => ()
  }
}

///|
/// | Record a complete enum definition.
pub fn CModule::define_enum(self : CModule, decl : CEnumDecl) -> Unit {
  self.enums[decl.tag] = decl
}

///|
/// | Give an enum a new canonical tag, mirroring `rename_record`. Used for
/// `typedef enum { ... } Name;`.
pub fn CModule::rename_enum(
  self : CModule,
  old_tag : String,
  new_tag : String,
) -> Unit {
  match self.enums.get(old_tag) {
    Some(decl) => {
      if self.enums.contains(new_tag) {
        return
      }
      self.enums.remove(old_tag)
      self.enums[new_tag] = {
        tag: new_tag,
        items: decl.items,
        complete: decl.complete,
      }
    }
    None => ()
  }
}

///|
/// | Bind a typedef name. The first binding wins: C forbids redefinition, and
/// keeping the earliest one makes repeated inclusion of a header harmless.
pub fn CModule::add_typedef(self : CModule, td : CTypedef) -> Unit {
  if !self.typedefs.contains(td.name) {
    self.typedefs[td.name] = td
  }
}

///|
/// | Look up a typedef by name.
pub fn CModule::typedef_of(self : CModule, name : String) -> CType? {
  match self.typedefs.get(name) {
    Some(td) => Some(td.ty)
    None => None
  }
}

///|
/// | Resolve a name through the typedef table, returning the name unchanged
/// when it is not a typedef. This is the callback shape that
/// `CType::resolve_names` expects.
pub fn CModule::resolver(self : CModule) -> (String) -> CType {
  fn(name) {
    match self.typedef_of(name) {
      Some(ty) => ty
      None => Named(name)
    }
  }
}

///|
/// | Resolve every alias in the module in place. Types that still name an
/// unknown identifier are left as `Named`, which the verifier reports.
pub fn CModule::resolve_all(self : CModule) -> Unit {
  let resolve = self.resolver()
  for _, td in self.typedefs {
    td.ty = td.ty.resolve_names(resolve)
  }
  for _, rec in self.records {
    for field in rec.fields {
      field.ty = field.ty.resolve_names(resolve)
    }
  }
  for fn_ in self.functions {
    fn_.ret = fn_.ret.resolve_names(resolve)
    for p in fn_.params {
      p.ty = p.ty.resolve_names(resolve)
    }
  }
}

///|
/// | Append a function declaration, dropping a previous declaration with the
/// same name. Headers routinely declare a function that a later header
/// re-declares with an equivalent prototype.
pub fn CModule::add_function(self : CModule, f : CFnDecl) -> Unit {
  let kept = self.functions.filter(g => g.name != f.name)
  self.functions.clear()
  self.functions.append(kept)
  self.functions.push(f)
}

///|
/// | Find a function by name.
pub fn CModule::function_named(self : CModule, name : String) -> CFnDecl? {
  for f in self.functions {
    if f.name == name {
      return Some(f)
    }
  }
  None
}

///|
/// | Sort the declaration tables into a deterministic order so that generated
/// output is reproducible across runs and across map implementations.
pub fn CModule::sorted_record_tags(self : CModule) -> Array[String] {
  let tags = []
  for tag, _ in self.records {
    tags.push(tag)
  }
  tags.sort()
  tags
}

///|
/// | Enum tags in sorted order.
pub fn CModule::sorted_enum_tags(self : CModule) -> Array[String] {
  let tags = []
  for tag, _ in self.enums {
    tags.push(tag)
  }
  tags.sort()
  tags
}

///|
/// | Typedef names in sorted order.
pub fn CModule::sorted_typedef_names(self : CModule) -> Array[String] {
  let names = []
  for name, _ in self.typedefs {
    names.push(name)
  }
  names.sort()
  names
}

///|
/// | Functions in declaration order, with internal-linkage ones removed.
pub fn CModule::exported_functions(self : CModule) -> Array[CFnDecl] {
  self.functions.filter(f => !f.internal)
}

///|
pub(all) struct Diagnostic {
  code : String
  file : String
  line : Int32
  column : Int32
  token : String
  message : String
} derive(Debug)
