// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:front_end/src/fasta/util/link.dart' show Link, LinkBuilder;
import 'package:js_runtime/shared/embedded_names.dart';
import 'package:kernel/ast.dart' as ir;
import 'package:kernel/class_hierarchy.dart' as ir;
import 'package:kernel/core_types.dart' as ir;
import 'package:kernel/type_algebra.dart' as ir;
import 'package:kernel/type_environment.dart' as ir;

import '../closure.dart' show BoxLocal, ThisLocal;
import '../common.dart';
import '../common/names.dart';
import '../common_elements.dart';
import '../compile_time_constants.dart';
import '../constants/constant_system.dart';
import '../constants/constructors.dart';
import '../constants/evaluation.dart';
import '../constants/expressions.dart';
import '../constants/values.dart';
import '../elements/entities.dart';
import '../elements/entity_utils.dart' as utils;
import '../elements/indexed.dart';
import '../elements/names.dart';
import '../elements/types.dart';
import '../environment.dart';
import '../ir/debug.dart';
import '../ir/element_map.dart';
import '../ir/types.dart';
import '../ir/visitors.dart';
import '../ir/util.dart';
import '../js/js.dart' as js;
import '../js_backend/constant_system_javascript.dart';
import '../js_backend/namer.dart';
import '../js_backend/native_data.dart';
import '../js_emitter/code_emitter_task.dart';
import '../kernel/element_map_impl.dart';
import '../kernel/env.dart';
import '../kernel/kelements.dart';
import '../native/native.dart' as native;
import '../options.dart';
import '../ordered_typeset.dart';
import '../ssa/type_builder.dart';
import '../universe/call_structure.dart';
import '../universe/selector.dart';
import '../universe/world_builder.dart';

import 'closure.dart';
import 'elements.dart';
import 'element_map.dart';
import 'env.dart';
import 'locals.dart';

/// Interface for kernel queries needed to implement the [CodegenWorldBuilder].
abstract class JsToWorldBuilder implements JsToElementMap {
  /// Returns `true` if [field] has a constant initializer.
  bool hasConstantFieldInitializer(FieldEntity field);

  /// Returns the constant initializer for [field].
  ConstantValue getConstantFieldInitializer(FieldEntity field);

  /// Calls [f] for each parameter of [function] providing the type and name of
  /// the parameter and the [defaultValue] if the parameter is optional.
  void forEachParameter(FunctionEntity function,
      void f(DartType type, String name, ConstantValue defaultValue));
}

abstract class JsToElementMapBase implements IrToElementMap {
  final CompilerOptions options;
  final DiagnosticReporter reporter;
  CommonElementsImpl _commonElements;
  JsElementEnvironment _elementEnvironment;
  DartTypeConverter _typeConverter;
  JsConstantEnvironment _constantEnvironment;
  KernelDartTypes _types;
  ir.TypeEnvironment _typeEnvironment;

  /// Library environment. Used for fast lookup.
  JProgramEnv env;

  final EntityDataEnvMap<IndexedLibrary, JLibraryData, JLibraryEnv> libraries =
      new EntityDataEnvMap<IndexedLibrary, JLibraryData, JLibraryEnv>();
  final EntityDataEnvMap<IndexedClass, JClassData, JClassEnv> classes =
      new EntityDataEnvMap<IndexedClass, JClassData, JClassEnv>();
  final EntityDataMap<IndexedMember, JMemberData> members =
      new EntityDataMap<IndexedMember, JMemberData>();
  final EntityDataMap<IndexedTypeVariable, JTypeVariableData> typeVariables =
      new EntityDataMap<IndexedTypeVariable, JTypeVariableData>();
  final EntityDataMap<IndexedTypedef, JTypedefData> typedefs =
      new EntityDataMap<IndexedTypedef, JTypedefData>();

  JsToElementMapBase(this.options, this.reporter, Environment environment) {
    _elementEnvironment = new JsElementEnvironment(this);
    _commonElements = new CommonElementsImpl(_elementEnvironment);
    _constantEnvironment = new JsConstantEnvironment(this, environment);
    _typeConverter = new DartTypeConverter(this);
    _types = new KernelDartTypes(this);
  }

  bool checkFamily(Entity entity);

  DartTypes get types => _types;

  JsElementEnvironment get elementEnvironment => _elementEnvironment;

  @override
  CommonElementsImpl get commonElements => _commonElements;

  /// NativeBasicData is need for computation of the default super class.
  NativeBasicData get nativeBasicData;

  FunctionEntity get _mainFunction {
    return env.mainMethod != null ? getMethodInternal(env.mainMethod) : null;
  }

  LibraryEntity get _mainLibrary {
    return env.mainMethod != null
        ? getLibraryInternal(env.mainMethod.enclosingLibrary)
        : null;
  }

  Iterable<LibraryEntity> get libraryListInternal;

  SourceSpan getSourceSpan(Spannable spannable, Entity currentElement) {
    SourceSpan fromSpannable(Spannable spannable) {
      if (spannable is IndexedLibrary &&
          spannable.libraryIndex < libraries.length) {
        JLibraryEnv env = libraries.getEnv(spannable);
        return computeSourceSpanFromTreeNode(env.library);
      } else if (spannable is IndexedClass &&
          spannable.classIndex < classes.length) {
        JClassData data = classes.getData(spannable);
        assert(data != null, "No data for $spannable in $this");
        return data.definition.location;
      } else if (spannable is IndexedMember &&
          spannable.memberIndex < members.length) {
        JMemberData data = members.getData(spannable);
        assert(data != null, "No data for $spannable in $this");
        return data.definition.location;
      } else if (spannable is JLocal) {
        return getSourceSpan(spannable.memberContext, currentElement);
      }
      return null;
    }

    SourceSpan sourceSpan = fromSpannable(spannable);
    sourceSpan ??= fromSpannable(currentElement);
    return sourceSpan;
  }

  LibraryEntity lookupLibrary(Uri uri) {
    JLibraryEnv libraryEnv = env.lookupLibrary(uri);
    if (libraryEnv == null) return null;
    return getLibraryInternal(libraryEnv.library, libraryEnv);
  }

  String _getLibraryName(IndexedLibrary library) {
    assert(checkFamily(library));
    JLibraryEnv libraryEnv = libraries.getEnv(library);
    return libraryEnv.library.name ?? '';
  }

  MemberEntity lookupLibraryMember(IndexedLibrary library, String name,
      {bool setter: false}) {
    assert(checkFamily(library));
    JLibraryEnv libraryEnv = libraries.getEnv(library);
    ir.Member member = libraryEnv.lookupMember(name, setter: setter);
    return member != null ? getMember(member) : null;
  }

  void _forEachLibraryMember(
      IndexedLibrary library, void f(MemberEntity member)) {
    assert(checkFamily(library));
    JLibraryEnv libraryEnv = libraries.getEnv(library);
    libraryEnv.forEachMember((ir.Member node) {
      f(getMember(node));
    });
  }

  ClassEntity lookupClass(IndexedLibrary library, String name) {
    assert(checkFamily(library));
    JLibraryEnv libraryEnv = libraries.getEnv(library);
    JClassEnv classEnv = libraryEnv.lookupClass(name);
    if (classEnv != null) {
      return getClassInternal(classEnv.cls, classEnv);
    }
    return null;
  }

  void _forEachClass(IndexedLibrary library, void f(ClassEntity cls)) {
    assert(checkFamily(library));
    JLibraryEnv libraryEnv = libraries.getEnv(library);
    libraryEnv.forEachClass((JClassEnv classEnv) {
      if (!classEnv.isUnnamedMixinApplication) {
        f(getClassInternal(classEnv.cls, classEnv));
      }
    });
  }

  MemberEntity lookupClassMember(IndexedClass cls, String name,
      {bool setter: false}) {
    assert(checkFamily(cls));
    JClassEnv classEnv = classes.getEnv(cls);
    return classEnv.lookupMember(this, name, setter: setter);
  }

  ConstructorEntity lookupConstructor(IndexedClass cls, String name) {
    assert(checkFamily(cls));
    JClassEnv classEnv = classes.getEnv(cls);
    return classEnv.lookupConstructor(this, name);
  }

  @override
  InterfaceType createInterfaceType(
      ir.Class cls, List<ir.DartType> typeArguments) {
    return new InterfaceType(getClass(cls), getDartTypes(typeArguments));
  }

  LibraryEntity getLibrary(ir.Library node) => getLibraryInternal(node);

  LibraryEntity getLibraryInternal(ir.Library node, [JLibraryEnv libraryEnv]);

  @override
  ClassEntity getClass(ir.Class node) => getClassInternal(node);

  ClassEntity getClassInternal(ir.Class node, [JClassEnv classEnv]);

  InterfaceType getSuperType(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.supertype;
  }

  void _ensureThisAndRawType(ClassEntity cls, JClassData data) {
    assert(checkFamily(cls));
    if (data is JClassDataImpl && data.thisType == null) {
      ir.Class node = data.cls;
      if (node.typeParameters.isEmpty) {
        data.thisType =
            data.rawType = new InterfaceType(cls, const <DartType>[]);
      } else {
        data.thisType = new InterfaceType(
            cls,
            new List<DartType>.generate(node.typeParameters.length,
                (int index) {
              return new TypeVariableType(
                  getTypeVariableInternal(node.typeParameters[index]));
            }));
        data.rawType = new InterfaceType(
            cls,
            new List<DartType>.filled(
                node.typeParameters.length, const DynamicType()));
      }
    }
  }

  TypeVariableEntity getTypeVariable(ir.TypeParameter node) =>
      getTypeVariableInternal(node);

  TypeVariableEntity getTypeVariableInternal(ir.TypeParameter node);

  void _ensureSupertypes(ClassEntity cls, JClassData data) {
    assert(checkFamily(cls));
    if (data is JClassDataImpl && data.orderedTypeSet == null) {
      _ensureThisAndRawType(cls, data);

      ir.Class node = data.cls;

      if (node.supertype == null) {
        data.orderedTypeSet = new OrderedTypeSet.singleton(data.thisType);
        data.isMixinApplication = false;
        data.interfaces = const <InterfaceType>[];
      } else {
        InterfaceType processSupertype(ir.Supertype node) {
          InterfaceType supertype = _typeConverter.visitSupertype(node);
          IndexedClass superclass = supertype.element;
          JClassData superdata = classes.getData(superclass);
          _ensureSupertypes(superclass, superdata);
          return supertype;
        }

        InterfaceType supertype;
        LinkBuilder<InterfaceType> linkBuilder =
            new LinkBuilder<InterfaceType>();
        if (node.isMixinDeclaration) {
          // A mixin declaration
          //
          //   mixin M on A, B, C {}
          //
          // is encoded by CFE as
          //
          //   abstract class M extends A with B, C {}
          //
          // but we encode it as
          //
          //   abstract class M extends Object implements A, B, C {}
          //
          // so we need to collect the non-Object superclasses and add them
          // to the interfaces of M.

          ir.Class superclass = node.superclass;
          while (superclass != null) {
            if (superclass.isAnonymousMixin) {
              // Add second to last mixed in superclasses. `B` and `C` in the
              // example above.
              ir.DartType mixinType = typeEnvironment.hierarchy
                  .getTypeAsInstanceOf(node.thisType, superclass.mixedInClass);
              linkBuilder.addLast(getDartType(mixinType));
            } else {
              // Add first mixed in superclass. `A` in the example above.
              ir.DartType mixinType = typeEnvironment.hierarchy
                  .getTypeAsInstanceOf(node.thisType, superclass);
              linkBuilder.addLast(getDartType(mixinType));
              break;
            }
            superclass = superclass.superclass;
          }
          // Set superclass to `Object`.
          supertype = _commonElements.objectType;
        } else {
          supertype = processSupertype(node.supertype);
        }
        if (supertype == _commonElements.objectType) {
          ClassEntity defaultSuperclass =
              _commonElements.getDefaultSuperclass(cls, nativeBasicData);
          data.supertype = _elementEnvironment.getRawType(defaultSuperclass);
        } else {
          data.supertype = supertype;
        }
        if (node.mixedInType != null) {
          data.isMixinApplication = true;
          linkBuilder
              .addLast(data.mixedInType = processSupertype(node.mixedInType));
        } else {
          data.isMixinApplication = false;
        }
        node.implementedTypes.forEach((ir.Supertype supertype) {
          linkBuilder.addLast(processSupertype(supertype));
        });
        Link<InterfaceType> interfaces =
            linkBuilder.toLink(const Link<InterfaceType>());
        OrderedTypeSetBuilder setBuilder =
            new KernelOrderedTypeSetBuilder(this, cls);
        data.orderedTypeSet = setBuilder.createOrderedTypeSet(
            data.supertype, interfaces.reverse(const Link<InterfaceType>()));
        data.interfaces = new List<InterfaceType>.from(interfaces.toList());
      }
    }
  }

  @override
  TypedefType getTypedefType(ir.Typedef node) {
    IndexedTypedef typedef = getTypedefInternal(node);
    return typedefs.getData(typedef).rawType;
  }

  TypedefEntity getTypedefInternal(ir.Typedef node);

  @override
  MemberEntity getMember(ir.Member node) {
    if (node is ir.Field) {
      return getFieldInternal(node);
    } else if (node is ir.Constructor) {
      return getConstructorInternal(node);
    } else if (node is ir.Procedure) {
      if (node.kind == ir.ProcedureKind.Factory) {
        return getConstructorInternal(node);
      } else {
        return getMethodInternal(node);
      }
    }
    throw new UnsupportedError("Unexpected member: $node");
  }

  MemberEntity getSuperMember(
      MemberEntity context, ir.Name name, ir.Member target,
      {bool setter: false}) {
    if (target != null && !target.isAbstract && target.isInstanceMember) {
      return getMember(target);
    }
    ClassEntity cls = context.enclosingClass;
    assert(
        cls != null,
        failedAt(context,
            "No enclosing class for super member access in $context."));
    IndexedClass superclass = getSuperType(cls)?.element;
    while (superclass != null) {
      JClassEnv env = classes.getEnv(superclass);
      MemberEntity superMember =
          env.lookupMember(this, name.name, setter: setter);
      if (superMember != null) {
        if (!superMember.isInstanceMember) return null;
        if (!superMember.isAbstract) {
          return superMember;
        }
      }
      superclass = getSuperType(superclass)?.element;
    }
    return null;
  }

  @override
  ConstructorEntity getConstructor(ir.Member node) =>
      getConstructorInternal(node);

  ConstructorEntity getConstructorInternal(ir.Member node);

  ConstructorEntity getSuperConstructor(
      ir.Constructor sourceNode, ir.Member targetNode) {
    ConstructorEntity source = getConstructor(sourceNode);
    ClassEntity sourceClass = source.enclosingClass;
    ConstructorEntity target = getConstructor(targetNode);
    ClassEntity targetClass = target.enclosingClass;
    IndexedClass superClass = getSuperType(sourceClass)?.element;
    if (superClass == targetClass) {
      return target;
    }
    JClassEnv env = classes.getEnv(superClass);
    ConstructorEntity constructor = env.lookupConstructor(this, target.name);
    if (constructor != null) {
      return constructor;
    }
    throw failedAt(source, "Super constructor for $source not found.");
  }

  @override
  FunctionEntity getMethod(ir.Procedure node) => getMethodInternal(node);

  FunctionEntity getMethodInternal(ir.Procedure node);

  @override
  FieldEntity getField(ir.Field node) => getFieldInternal(node);

  FieldEntity getFieldInternal(ir.Field node);

  @override
  DartType getDartType(ir.DartType type) => _typeConverter.convert(type);

  TypeVariableType getTypeVariableType(ir.TypeParameterType type) =>
      getDartType(type);

  List<DartType> getDartTypes(List<ir.DartType> types) {
    List<DartType> list = <DartType>[];
    types.forEach((ir.DartType type) {
      list.add(getDartType(type));
    });
    return list;
  }

  InterfaceType getInterfaceType(ir.InterfaceType type) =>
      _typeConverter.convert(type);

  @override
  FunctionType getFunctionType(ir.FunctionNode node) {
    DartType returnType;
    if (node.parent is ir.Constructor) {
      // The return type on generative constructors is `void`, but we need
      // `dynamic` type to match the element model.
      returnType = const DynamicType();
    } else {
      returnType = getDartType(node.returnType);
    }
    List<DartType> parameterTypes = <DartType>[];
    List<DartType> optionalParameterTypes = <DartType>[];

    DartType getParameterType(ir.VariableDeclaration variable) {
      if (variable.isCovariant || variable.isGenericCovariantImpl) {
        // A covariant parameter has type `Object` in the method signature.
        return commonElements.objectType;
      }
      return getDartType(variable.type);
    }

    for (ir.VariableDeclaration variable in node.positionalParameters) {
      if (parameterTypes.length == node.requiredParameterCount) {
        optionalParameterTypes.add(getParameterType(variable));
      } else {
        parameterTypes.add(getParameterType(variable));
      }
    }
    List<String> namedParameters = <String>[];
    List<DartType> namedParameterTypes = <DartType>[];
    List<ir.VariableDeclaration> sortedNamedParameters =
        node.namedParameters.toList()..sort((a, b) => a.name.compareTo(b.name));
    for (ir.VariableDeclaration variable in sortedNamedParameters) {
      namedParameters.add(variable.name);
      namedParameterTypes.add(getParameterType(variable));
    }
    List<FunctionTypeVariable> typeVariables;
    if (node.typeParameters.isNotEmpty) {
      List<DartType> typeParameters = <DartType>[];
      for (ir.TypeParameter typeParameter in node.typeParameters) {
        typeParameters
            .add(getDartType(new ir.TypeParameterType(typeParameter)));
      }
      typeVariables = new List<FunctionTypeVariable>.generate(
          node.typeParameters.length,
          (int index) => new FunctionTypeVariable(index));

      DartType subst(DartType type) {
        return type.subst(typeVariables, typeParameters);
      }

      returnType = subst(returnType);
      parameterTypes = parameterTypes.map(subst).toList();
      optionalParameterTypes = optionalParameterTypes.map(subst).toList();
      namedParameterTypes = namedParameterTypes.map(subst).toList();
      for (int index = 0; index < typeVariables.length; index++) {
        typeVariables[index].bound =
            subst(getDartType(node.typeParameters[index].bound));
      }
    } else {
      typeVariables = const <FunctionTypeVariable>[];
    }

    return new FunctionType(returnType, parameterTypes, optionalParameterTypes,
        namedParameters, namedParameterTypes, typeVariables);
  }

  ConstantValue computeConstantValue(
      Spannable spannable, ConstantExpression constant,
      {bool requireConstant: true}) {
    return _constantEnvironment._getConstantValue(spannable, constant,
        constantRequired: requireConstant);
  }

  DartType substByContext(DartType type, InterfaceType context) {
    return type.subst(
        context.typeArguments, getThisType(context.element).typeArguments);
  }

  /// Returns the type of the `call` method on 'type'.
  ///
  /// If [type] doesn't have a `call` member `null` is returned. If [type] has
  /// an invalid `call` member (non-method or a synthesized method with both
  /// optional and named parameters) a [DynamicType] is returned.
  DartType getCallType(InterfaceType type) {
    IndexedClass cls = type.element;
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    if (data.callType != null) {
      return substByContext(data.callType, type);
    }
    return null;
  }

  InterfaceType getThisType(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureThisAndRawType(cls, data);
    return data.thisType;
  }

  InterfaceType _getRawType(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureThisAndRawType(cls, data);
    return data.rawType;
  }

  FunctionType _getFunctionType(IndexedFunction function) {
    assert(checkFamily(function));
    FunctionData data = members.getData(function);
    return data.getFunctionType(this);
  }

  List<TypeVariableType> _getFunctionTypeVariables(IndexedFunction function) {
    assert(checkFamily(function));
    FunctionData data = members.getData(function);
    return data.getFunctionTypeVariables(this);
  }

  DartType _getFieldType(IndexedField field) {
    assert(checkFamily(field));
    JFieldData data = members.getData(field);
    return data.getFieldType(this);
  }

  DartType getTypeVariableBound(IndexedTypeVariable typeVariable) {
    assert(checkFamily(typeVariable));
    JTypeVariableData data = typeVariables.getData(typeVariable);
    return data.getBound(this);
  }

  DartType _getTypeVariableDefaultType(IndexedTypeVariable typeVariable) {
    assert(checkFamily(typeVariable));
    JTypeVariableData data = typeVariables.getData(typeVariable);
    return data.getDefaultType(this);
  }

  ClassEntity getAppliedMixin(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.mixedInType?.element;
  }

  bool _isMixinApplication(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.isMixinApplication;
  }

  bool _isUnnamedMixinApplication(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassEnv env = classes.getEnv(cls);
    return env.isUnnamedMixinApplication;
  }

  bool _isSuperMixinApplication(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassEnv env = classes.getEnv(cls);
    return env.isSuperMixinApplication;
  }

  void _forEachSupertype(IndexedClass cls, void f(InterfaceType supertype)) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    data.orderedTypeSet.supertypes.forEach(f);
  }

  void _forEachConstructor(IndexedClass cls, void f(ConstructorEntity member)) {
    assert(checkFamily(cls));
    JClassEnv env = classes.getEnv(cls);
    env.forEachConstructor(this, f);
  }

  void forEachConstructorBody(
      IndexedClass cls, void f(ConstructorBodyEntity member)) {
    throw new UnsupportedError(
        'KernelToElementMapBase._forEachConstructorBody');
  }

  void forEachNestedClosure(
      MemberEntity member, void f(FunctionEntity closure));

  void _forEachLocalClassMember(IndexedClass cls, void f(MemberEntity member)) {
    assert(checkFamily(cls));
    JClassEnv env = classes.getEnv(cls);
    env.forEachMember(this, (MemberEntity member) {
      f(member);
    });
  }

  void forEachInjectedClassMember(
      IndexedClass cls, void f(MemberEntity member)) {
    assert(checkFamily(cls));
    throw new UnsupportedError(
        'KernelToElementMapBase._forEachInjectedClassMember');
  }

  void _forEachClassMember(
      IndexedClass cls, void f(ClassEntity cls, MemberEntity member)) {
    assert(checkFamily(cls));
    JClassEnv env = classes.getEnv(cls);
    env.forEachMember(this, (MemberEntity member) {
      f(cls, member);
    });
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    if (data.supertype != null) {
      _forEachClassMember(data.supertype.element, f);
    }
  }

  ConstantConstructor _getConstructorConstant(IndexedConstructor constructor) {
    assert(checkFamily(constructor));
    JConstructorData data = members.getData(constructor);
    return data.getConstructorConstant(this, constructor);
  }

  ConstantExpression _getFieldConstantExpression(IndexedField field) {
    assert(checkFamily(field));
    JFieldData data = members.getData(field);
    return data.getFieldConstantExpression(this);
  }

  InterfaceType asInstanceOf(InterfaceType type, ClassEntity cls) {
    assert(checkFamily(cls));
    OrderedTypeSet orderedTypeSet = getOrderedTypeSet(type.element);
    InterfaceType supertype =
        orderedTypeSet.asInstanceOf(cls, getHierarchyDepth(cls));
    if (supertype != null) {
      supertype = substByContext(supertype, type);
    }
    return supertype;
  }

  OrderedTypeSet getOrderedTypeSet(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.orderedTypeSet;
  }

  int getHierarchyDepth(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.orderedTypeSet.maxDepth;
  }

  Iterable<InterfaceType> getInterfaces(IndexedClass cls) {
    assert(checkFamily(cls));
    JClassData data = classes.getData(cls);
    _ensureSupertypes(cls, data);
    return data.interfaces;
  }

  MemberDefinition getMemberDefinitionInternal(covariant IndexedMember member) {
    assert(checkFamily(member));
    return members.getData(member).definition;
  }

  ClassDefinition getClassDefinitionInternal(covariant IndexedClass cls) {
    assert(checkFamily(cls));
    return classes.getData(cls).definition;
  }

  ImportEntity getImport(ir.LibraryDependency node) {
    ir.Library library = node.parent;
    JLibraryData data = libraries.getData(getLibraryInternal(library));
    return data.imports[node];
  }

  ir.TypeEnvironment get typeEnvironment {
    if (_typeEnvironment == null) {
      _typeEnvironment ??= new ir.TypeEnvironment(
          new ir.CoreTypes(env.mainComponent),
          new ir.ClassHierarchy(env.mainComponent));
    }
    return _typeEnvironment;
  }

  DartType getStaticType(ir.Expression node) {
    ir.TreeNode enclosingClass = node;
    while (enclosingClass != null && enclosingClass is! ir.Class) {
      enclosingClass = enclosingClass.parent;
    }
    try {
      typeEnvironment.thisType =
          enclosingClass is ir.Class ? enclosingClass.thisType : null;
      return getDartType(node.getStaticType(typeEnvironment));
    } catch (e) {
      // The static type computation crashes on type errors. Use `dynamic`
      // as static type.
      return commonElements.dynamicType;
    }
  }

  Name getName(ir.Name name) {
    return new Name(
        name.name, name.isPrivate ? getLibrary(name.library) : null);
  }

  CallStructure getCallStructure(ir.Arguments arguments) {
    int argumentCount = arguments.positional.length + arguments.named.length;
    List<String> namedArguments = arguments.named.map((e) => e.name).toList();
    return new CallStructure(
        argumentCount, namedArguments, arguments.types.length);
  }

  ParameterStructure getParameterStructure(ir.FunctionNode node,
      // TODO(johnniwinther): Remove this when type arguments are passed to
      // constructors like calling a generic method.
      {bool includeTypeParameters: true}) {
    // TODO(johnniwinther): Cache the computed function type.
    int requiredParameters = node.requiredParameterCount;
    int positionalParameters = node.positionalParameters.length;
    int typeParameters = node.typeParameters.length;
    List<String> namedParameters =
        node.namedParameters.map((p) => p.name).toList()..sort();
    return new ParameterStructure(requiredParameters, positionalParameters,
        namedParameters, includeTypeParameters ? typeParameters : 0);
  }

  Selector getSelector(ir.Expression node) {
    // TODO(efortuna): This is screaming for a common interface between
    // PropertyGet and SuperPropertyGet (and same for *Get). Talk to kernel
    // folks.
    if (node is ir.PropertyGet) {
      return getGetterSelector(node.name);
    }
    if (node is ir.SuperPropertyGet) {
      return getGetterSelector(node.name);
    }
    if (node is ir.PropertySet) {
      return getSetterSelector(node.name);
    }
    if (node is ir.SuperPropertySet) {
      return getSetterSelector(node.name);
    }
    if (node is ir.InvocationExpression) {
      return getInvocationSelector(node);
    }
    throw failedAt(
        CURRENT_ELEMENT_SPANNABLE,
        "Can only get the selector for a property get or an invocation: "
        "${node}");
  }

  Selector getInvocationSelector(ir.InvocationExpression invocation) {
    Name name = getName(invocation.name);
    SelectorKind kind;
    if (Selector.isOperatorName(name.text)) {
      if (name == Names.INDEX_NAME || name == Names.INDEX_SET_NAME) {
        kind = SelectorKind.INDEX;
      } else {
        kind = SelectorKind.OPERATOR;
      }
    } else {
      kind = SelectorKind.CALL;
    }

    CallStructure callStructure = getCallStructure(invocation.arguments);
    return new Selector(kind, name, callStructure);
  }

  Selector getGetterSelector(ir.Name irName) {
    Name name = new Name(
        irName.name, irName.isPrivate ? getLibrary(irName.library) : null);
    return new Selector.getter(name);
  }

  Selector getSetterSelector(ir.Name irName) {
    Name name = new Name(
        irName.name, irName.isPrivate ? getLibrary(irName.library) : null);
    return new Selector.setter(name);
  }

  /// Looks up [typeName] for use in the spec-string of a `JS` call.
  // TODO(johnniwinther): Use this in [native.NativeBehavior] instead of calling
  // the `ForeignResolver`.
  native.TypeLookup typeLookup({bool resolveAsRaw: true}) {
    return resolveAsRaw
        ? (_cachedTypeLookupRaw ??= _typeLookup(resolveAsRaw: true))
        : (_cachedTypeLookupFull ??= _typeLookup(resolveAsRaw: false));
  }

  native.TypeLookup _cachedTypeLookupRaw;
  native.TypeLookup _cachedTypeLookupFull;

  native.TypeLookup _typeLookup({bool resolveAsRaw: true}) {
    bool cachedMayLookupInMain;
    bool mayLookupInMain() {
      var mainUri = elementEnvironment.mainLibrary.canonicalUri;
      // Tests permit lookup outside of dart: libraries.
      return mainUri.path.contains('tests/compiler/dart2js_native') ||
          mainUri.path.contains('tests/compiler/dart2js_extra');
    }

    DartType lookup(String typeName, {bool required}) {
      DartType findInLibrary(LibraryEntity library) {
        if (library != null) {
          ClassEntity cls = elementEnvironment.lookupClass(library, typeName);
          if (cls != null) {
            // TODO(johnniwinther): Align semantics.
            return resolveAsRaw
                ? elementEnvironment.getRawType(cls)
                : elementEnvironment.getThisType(cls);
          }
        }
        return null;
      }

      DartType findIn(Uri uri) {
        return findInLibrary(elementEnvironment.lookupLibrary(uri));
      }

      // TODO(johnniwinther): Narrow the set of lookups based on the depending
      // library.
      // TODO(johnniwinther): Cache more results to avoid redundant lookups?
      DartType type;
      if (cachedMayLookupInMain ??= mayLookupInMain()) {
        type ??= findInLibrary(elementEnvironment.mainLibrary);
      }
      type ??= findIn(Uris.dart_core);
      type ??= findIn(Uris.dart__js_helper);
      type ??= findIn(Uris.dart__interceptors);
      type ??= findIn(Uris.dart__native_typed_data);
      type ??= findIn(Uris.dart_collection);
      type ??= findIn(Uris.dart_math);
      type ??= findIn(Uris.dart_html);
      type ??= findIn(Uris.dart_html_common);
      type ??= findIn(Uris.dart_svg);
      type ??= findIn(Uris.dart_web_audio);
      type ??= findIn(Uris.dart_web_gl);
      type ??= findIn(Uris.dart_web_sql);
      type ??= findIn(Uris.dart_indexed_db);
      type ??= findIn(Uris.dart_typed_data);
      type ??= findIn(Uris.dart_mirrors);
      if (type == null && required) {
        reporter.reportErrorMessage(CURRENT_ELEMENT_SPANNABLE,
            MessageKind.GENERIC, {'text': "Type '$typeName' not found."});
      }
      return type;
    }

    return lookup;
  }

  String _getStringArgument(ir.StaticInvocation node, int index) {
    return node.arguments.positional[index].accept(new Stringifier());
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsCall(ir.StaticInvocation node) {
    if (node.arguments.positional.length < 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS);
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_FIRST);
      return new native.NativeBehavior();
    }

    String codeString = _getStringArgument(node, 1);
    if (codeString == null) {
      reporter.reportErrorMessage(
          CURRENT_ELEMENT_SPANNABLE, MessageKind.WRONG_ARGUMENT_FOR_JS_SECOND);
      return new native.NativeBehavior();
    }

    return native.NativeBehavior.ofJsCall(
        specString,
        codeString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the [JS_BUILTIN]
  /// function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsBuiltinCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS builtin is missing name.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsBuiltinCall(
        specString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  /// Computes the [native.NativeBehavior] for a call to the
  /// [JS_EMBEDDED_GLOBAL] function.
  // TODO(johnniwinther): Cache this for later use.
  native.NativeBehavior getNativeBehaviorForJsEmbeddedGlobalCall(
      ir.StaticInvocation node) {
    if (node.arguments.positional.length < 1) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global expression has no type.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length < 2) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "JS embedded global is missing name.");
      return new native.NativeBehavior();
    }
    if (node.arguments.positional.length > 2 ||
        node.arguments.named.isNotEmpty) {
      reporter.internalError(CURRENT_ELEMENT_SPANNABLE,
          "JS embedded global has more than 2 arguments.");
      return new native.NativeBehavior();
    }
    String specString = _getStringArgument(node, 0);
    if (specString == null) {
      reporter.internalError(
          CURRENT_ELEMENT_SPANNABLE, "Unexpected first argument.");
      return new native.NativeBehavior();
    }
    return native.NativeBehavior.ofJsEmbeddedGlobalCall(
        specString,
        typeLookup(resolveAsRaw: true),
        CURRENT_ELEMENT_SPANNABLE,
        reporter,
        commonElements);
  }

  js.Name getNameForJsGetName(ConstantValue constant, Namer namer) {
    int index = extractEnumIndexFromConstantValue(
        constant, commonElements.jsGetNameEnum);
    if (index == null) return null;
    return namer.getNameForJsGetName(
        CURRENT_ELEMENT_SPANNABLE, JsGetName.values[index]);
  }

  int extractEnumIndexFromConstantValue(
      ConstantValue constant, ClassEntity classElement) {
    if (constant is ConstructedConstantValue) {
      if (constant.type.element == classElement) {
        assert(constant.fields.length == 1 || constant.fields.length == 2);
        ConstantValue indexConstant = constant.fields.values.first;
        if (indexConstant is IntConstantValue) {
          return indexConstant.intValue.toInt();
        }
      }
    }
    return null;
  }

  ConstantValue getConstantValue(ir.Expression node,
      {bool requireConstant: true, bool implicitNull: false}) {
    ConstantExpression constant;
    if (node == null) {
      if (!implicitNull) {
        throw failedAt(
            CURRENT_ELEMENT_SPANNABLE, 'No expression for constant.');
      }
      constant = new NullConstantExpression();
    } else {
      constant =
          new Constantifier(this, requireConstant: requireConstant).visit(node);
    }
    if (constant == null) {
      if (requireConstant) {
        throw new UnsupportedError(
            'No constant for ${DebugPrinter.prettyPrint(node)}');
      }
      return null;
    }
    ConstantValue value = computeConstantValue(
        computeSourceSpanFromTreeNode(node), constant,
        requireConstant: requireConstant);
    if (!value.isConstant && !requireConstant) {
      return null;
    }
    return value;
  }

  /// Converts [annotations] into a list of [ConstantValue]s.
  List<ConstantValue> getMetadata(List<ir.Expression> annotations) {
    if (annotations.isEmpty) return const <ConstantValue>[];
    List<ConstantValue> metadata = <ConstantValue>[];
    annotations.forEach((ir.Expression node) {
      metadata.add(getConstantValue(node));
    });
    return metadata;
  }

  FunctionEntity getSuperNoSuchMethod(ClassEntity cls) {
    while (cls != null) {
      cls = elementEnvironment.getSuperClass(cls);
      MemberEntity member = elementEnvironment.lookupLocalClassMember(
          cls, Identifiers.noSuchMethod_);
      if (member != null && !member.isAbstract) {
        if (member.isFunction) {
          FunctionEntity function = member;
          if (function.parameterStructure.positionalParameters >= 1) {
            return function;
          }
        }
        // If [member] is not a valid `noSuchMethod` the target is
        // `Object.superNoSuchMethod`.
        break;
      }
    }
    FunctionEntity function = elementEnvironment.lookupLocalClassMember(
        commonElements.objectClass, Identifiers.noSuchMethod_);
    assert(function != null,
        failedAt(cls, "No super noSuchMethod found for class $cls."));
    return function;
  }
}

class JsElementEnvironment extends ElementEnvironment
    implements JElementEnvironment {
  final JsToElementMapBase elementMap;

  JsElementEnvironment(this.elementMap);

  @override
  DartType get dynamicType => const DynamicType();

  @override
  LibraryEntity get mainLibrary => elementMap._mainLibrary;

  @override
  FunctionEntity get mainFunction => elementMap._mainFunction;

  @override
  Iterable<LibraryEntity> get libraries => elementMap.libraryListInternal;

  @override
  String getLibraryName(LibraryEntity library) {
    return elementMap._getLibraryName(library);
  }

  @override
  InterfaceType getThisType(ClassEntity cls) {
    return elementMap.getThisType(cls);
  }

  @override
  InterfaceType getRawType(ClassEntity cls) {
    return elementMap._getRawType(cls);
  }

  @override
  bool isGenericClass(ClassEntity cls) {
    return getThisType(cls).typeArguments.isNotEmpty;
  }

  @override
  bool isMixinApplication(ClassEntity cls) {
    return elementMap._isMixinApplication(cls);
  }

  @override
  bool isUnnamedMixinApplication(ClassEntity cls) {
    return elementMap._isUnnamedMixinApplication(cls);
  }

  @override
  bool isSuperMixinApplication(ClassEntity cls) {
    return elementMap._isSuperMixinApplication(cls);
  }

  @override
  ClassEntity getEffectiveMixinClass(ClassEntity cls) {
    if (!isMixinApplication(cls)) return null;
    do {
      cls = elementMap.getAppliedMixin(cls);
    } while (isMixinApplication(cls));
    return cls;
  }

  @override
  DartType getTypeVariableBound(TypeVariableEntity typeVariable) {
    return elementMap.getTypeVariableBound(typeVariable);
  }

  @override
  DartType getTypeVariableDefaultType(TypeVariableEntity typeVariable) {
    return elementMap._getTypeVariableDefaultType(typeVariable);
  }

  @override
  InterfaceType createInterfaceType(
      ClassEntity cls, List<DartType> typeArguments) {
    return new InterfaceType(cls, typeArguments);
  }

  @override
  FunctionType getFunctionType(FunctionEntity function) {
    return elementMap._getFunctionType(function);
  }

  @override
  List<TypeVariableType> getFunctionTypeVariables(FunctionEntity function) {
    return elementMap._getFunctionTypeVariables(function);
  }

  @override
  DartType getFunctionAsyncOrSyncStarElementType(FunctionEntity function) {
    // TODO(sra): Should be getting the DartType from the node.
    DartType returnType = getFunctionType(function).returnType;
    return getAsyncOrSyncStarElementType(function.asyncMarker, returnType);
  }

  @override
  DartType getAsyncOrSyncStarElementType(
      AsyncMarker asyncMarker, DartType returnType) {
    switch (asyncMarker) {
      case AsyncMarker.SYNC:
        return returnType;
      case AsyncMarker.SYNC_STAR:
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.iterableClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
      case AsyncMarker.ASYNC:
        if (returnType is FutureOrType) return returnType.typeArgument;
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.futureClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
      case AsyncMarker.ASYNC_STAR:
        if (returnType is InterfaceType) {
          if (returnType.element == elementMap.commonElements.streamClass) {
            return returnType.typeArguments.first;
          }
        }
        return dynamicType;
    }
    assert(false, 'Unexpected marker ${asyncMarker}');
    return null;
  }

  @override
  DartType getFieldType(FieldEntity field) {
    return elementMap._getFieldType(field);
  }

  @override
  FunctionType getLocalFunctionType(covariant KLocalFunction function) {
    return function.functionType;
  }

  @override
  DartType getUnaliasedType(DartType type) => type;

  @override
  ConstructorEntity lookupConstructor(ClassEntity cls, String name,
      {bool required: false}) {
    ConstructorEntity constructor = elementMap.lookupConstructor(cls, name);
    if (constructor == null && required) {
      throw failedAt(
          CURRENT_ELEMENT_SPANNABLE,
          "The constructor '$name' was not found in class '${cls.name}' "
          "in library ${cls.library.canonicalUri}.");
    }
    return constructor;
  }

  @override
  MemberEntity lookupLocalClassMember(ClassEntity cls, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupClassMember(cls, name, setter: setter);
    if (member == null && required) {
      throw failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The member '$name' was not found in ${cls.name}.");
    }
    return member;
  }

  @override
  ClassEntity getSuperClass(ClassEntity cls,
      {bool skipUnnamedMixinApplications: false}) {
    assert(elementMap.checkFamily(cls));
    ClassEntity superclass = elementMap.getSuperType(cls)?.element;
    if (skipUnnamedMixinApplications) {
      while (superclass != null &&
          elementMap._isUnnamedMixinApplication(superclass)) {
        superclass = elementMap.getSuperType(superclass)?.element;
      }
    }
    return superclass;
  }

  @override
  void forEachSupertype(ClassEntity cls, void f(InterfaceType supertype)) {
    elementMap._forEachSupertype(cls, f);
  }

  @override
  void forEachLocalClassMember(ClassEntity cls, void f(MemberEntity member)) {
    elementMap._forEachLocalClassMember(cls, f);
  }

  @override
  void forEachInjectedClassMember(
      ClassEntity cls, void f(MemberEntity member)) {
    elementMap.forEachInjectedClassMember(cls, f);
  }

  @override
  void forEachClassMember(
      ClassEntity cls, void f(ClassEntity declarer, MemberEntity member)) {
    elementMap._forEachClassMember(cls, f);
  }

  @override
  void forEachConstructor(
      ClassEntity cls, void f(ConstructorEntity constructor)) {
    elementMap._forEachConstructor(cls, f);
  }

  @override
  void forEachConstructorBody(
      ClassEntity cls, void f(ConstructorBodyEntity constructor)) {
    elementMap.forEachConstructorBody(cls, f);
  }

  @override
  void forEachNestedClosure(
      MemberEntity member, void f(FunctionEntity closure)) {
    elementMap.forEachNestedClosure(member, f);
  }

  @override
  void forEachLibraryMember(
      LibraryEntity library, void f(MemberEntity member)) {
    elementMap._forEachLibraryMember(library, f);
  }

  @override
  MemberEntity lookupLibraryMember(LibraryEntity library, String name,
      {bool setter: false, bool required: false}) {
    MemberEntity member =
        elementMap.lookupLibraryMember(library, name, setter: setter);
    if (member == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The member '${name}' was not found in library '${library.name}'.");
    }
    return member;
  }

  @override
  ClassEntity lookupClass(LibraryEntity library, String name,
      {bool required: false}) {
    ClassEntity cls = elementMap.lookupClass(library, name);
    if (cls == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE,
          "The class '$name'  was not found in library '${library.name}'.");
    }
    return cls;
  }

  @override
  void forEachClass(LibraryEntity library, void f(ClassEntity cls)) {
    elementMap._forEachClass(library, f);
  }

  @override
  LibraryEntity lookupLibrary(Uri uri, {bool required: false}) {
    LibraryEntity library = elementMap.lookupLibrary(uri);
    if (library == null && required) {
      failedAt(CURRENT_ELEMENT_SPANNABLE, "The library '$uri' was not found.");
    }
    return library;
  }

  @override
  bool isEnumClass(ClassEntity cls) {
    assert(elementMap.checkFamily(cls));
    JClassData classData = elementMap.classes.getData(cls);
    return classData.isEnumClass;
  }
}

/// [native.BehaviorBuilder] for kernel based elements.
class JsBehaviorBuilder extends native.BehaviorBuilder {
  final ElementEnvironment elementEnvironment;
  final CommonElements commonElements;
  final DiagnosticReporter reporter;
  final NativeBasicData nativeBasicData;
  final CompilerOptions _options;

  JsBehaviorBuilder(this.elementEnvironment, this.commonElements,
      this.nativeBasicData, this.reporter, this._options);

  @override
  bool get trustJSInteropTypeAnnotations =>
      _options.trustJSInteropTypeAnnotations;
}

/// Constant environment mapping [ConstantExpression]s to [ConstantValue]s using
/// [_EvaluationEnvironment] for the evaluation.
class JsConstantEnvironment implements ConstantEnvironment {
  final JsToElementMapBase _elementMap;
  final Environment _environment;

  Map<ConstantExpression, ConstantValue> _valueMap =
      <ConstantExpression, ConstantValue>{};

  JsConstantEnvironment(this._elementMap, this._environment);

  @override
  ConstantSystem get constantSystem => JavaScriptConstantSystem.only;

  ConstantValue _getConstantValue(
      Spannable spannable, ConstantExpression expression,
      {bool constantRequired}) {
    return _valueMap.putIfAbsent(expression, () {
      return expression.evaluate(
          new JsEvaluationEnvironment(_elementMap, _environment, spannable,
              constantRequired: constantRequired),
          constantSystem);
    });
  }
}

/// Evaluation environment used for computing [ConstantValue]s for
/// kernel based [ConstantExpression]s.
class JsEvaluationEnvironment extends EvaluationEnvironmentBase {
  final JsToElementMapBase _elementMap;
  final Environment _environment;

  JsEvaluationEnvironment(
      this._elementMap, this._environment, Spannable spannable,
      {bool constantRequired})
      : super(spannable, constantRequired: constantRequired);

  @override
  CommonElements get commonElements => _elementMap.commonElements;

  @override
  DartTypes get types => _elementMap.types;

  @override
  DartType substByContext(DartType base, InterfaceType target) {
    return _elementMap.substByContext(base, target);
  }

  @override
  ConstantConstructor getConstructorConstant(ConstructorEntity constructor) {
    return _elementMap._getConstructorConstant(constructor);
  }

  @override
  ConstantExpression getFieldConstant(FieldEntity field) {
    return _elementMap._getFieldConstantExpression(field);
  }

  @override
  ConstantExpression getLocalConstant(Local local) {
    throw new UnimplementedError("_EvaluationEnvironment.getLocalConstant");
  }

  @override
  String readFromEnvironment(String name) {
    return _environment.valueOf(name);
  }

  @override
  DiagnosticReporter get reporter => _elementMap.reporter;

  @override
  bool get enableAssertions => _elementMap.options.enableUserAssertions;
}

class JsKernelToElementMap extends JsToElementMapBase
    with JsElementCreatorMixin
    implements JsToWorldBuilder, JsToElementMap {
  final Map<ir.Library, IndexedLibrary> libraryMap = {};
  final Map<ir.Class, IndexedClass> classMap = {};
  final Map<ir.Typedef, IndexedTypedef> typedefMap = {};

  /// Map from [ir.TypeParameter] nodes to the corresponding
  /// [TypeVariableEntity].
  ///
  /// Normally the type variables are [IndexedTypeVariable]s, but for type
  /// parameters on local function (in the frontend) these are _not_ since
  /// their type declaration is neither a class nor a member. In the backend,
  /// these type parameters belong to the call-method and are therefore indexed.
  final Map<ir.TypeParameter, TypeVariableEntity> typeVariableMap = {};
  final Map<ir.Member, IndexedConstructor> constructorMap = {};
  final Map<ir.Procedure, IndexedFunction> methodMap = {};
  final Map<ir.Field, IndexedField> fieldMap = {};
  final Map<ir.TreeNode, Local> localFunctionMap = {};

  /// Map from members to the call methods created for their nested closures.
  Map<MemberEntity, List<FunctionEntity>> _nestedClosureMap =
      <MemberEntity, List<FunctionEntity>>{};

  @override
  NativeBasicData nativeBasicData;

  Map<FunctionEntity, JGeneratorBody> _generatorBodies = {};

  Map<ClassEntity, List<MemberEntity>> _injectedClassMembers = {};

  JsKernelToElementMap(DiagnosticReporter reporter, Environment environment,
      KernelToElementMapImpl _elementMap, Iterable<MemberEntity> liveMembers)
      : super(_elementMap.options, reporter, environment) {
    env = _elementMap.env.convert();
    for (int libraryIndex = 0;
        libraryIndex < _elementMap.libraries.length;
        libraryIndex++) {
      IndexedLibrary oldLibrary = _elementMap.libraries.getEntity(libraryIndex);
      KLibraryEnv oldEnv = _elementMap.libraries.getEnv(oldLibrary);
      KLibraryData data = _elementMap.libraries.getData(oldLibrary);
      IndexedLibrary newLibrary = convertLibrary(oldLibrary);
      JLibraryEnv newEnv = oldEnv.convert(_elementMap, liveMembers);
      libraryMap[oldEnv.library] =
          libraries.register<IndexedLibrary, JLibraryData, JLibraryEnv>(
              newLibrary, data.convert(), newEnv);
      assert(newLibrary.libraryIndex == oldLibrary.libraryIndex);
      env.registerLibrary(newEnv);
    }
    // TODO(johnniwinther): Filter unused classes.
    for (int classIndex = 0;
        classIndex < _elementMap.classes.length;
        classIndex++) {
      IndexedClass oldClass = _elementMap.classes.getEntity(classIndex);
      KClassEnv env = _elementMap.classes.getEnv(oldClass);
      KClassData data = _elementMap.classes.getData(oldClass);
      IndexedLibrary oldLibrary = oldClass.library;
      LibraryEntity newLibrary = libraries.getEntity(oldLibrary.libraryIndex);
      IndexedClass newClass = convertClass(newLibrary, oldClass);
      JClassEnv newEnv = env.convert(_elementMap, liveMembers);
      classMap[env.cls] =
          classes.register(newClass, data.convert(newClass), newEnv);
      assert(newClass.classIndex == oldClass.classIndex);
      libraries.getEnv(newClass.library).registerClass(newClass.name, newEnv);
    }
    for (int typedefIndex = 0;
        typedefIndex < _elementMap.typedefs.length;
        typedefIndex++) {
      IndexedTypedef oldTypedef = _elementMap.typedefs.getEntity(typedefIndex);
      KTypedefData data = _elementMap.typedefs.getData(oldTypedef);
      IndexedLibrary oldLibrary = oldTypedef.library;
      LibraryEntity newLibrary = libraries.getEntity(oldLibrary.libraryIndex);
      IndexedTypedef newTypedef = convertTypedef(newLibrary, oldTypedef);
      typedefMap[data.node] = typedefs.register(
          newTypedef,
          new JTypedefData(
              newTypedef,
              new TypedefType(
                  newTypedef,
                  new List<DartType>.filled(
                      data.node.typeParameters.length, const DynamicType()),
                  getDartType(data.node.type))));
      assert(newTypedef.typedefIndex == oldTypedef.typedefIndex);
    }
    for (int memberIndex = 0;
        memberIndex < _elementMap.members.length;
        memberIndex++) {
      IndexedMember oldMember = _elementMap.members.getEntity(memberIndex);
      if (!liveMembers.contains(oldMember)) {
        members.skipIndex(oldMember.memberIndex);
        continue;
      }
      KMemberData data = _elementMap.members.getData(oldMember);
      IndexedLibrary oldLibrary = oldMember.library;
      IndexedClass oldClass = oldMember.enclosingClass;
      LibraryEntity newLibrary = libraries.getEntity(oldLibrary.libraryIndex);
      ClassEntity newClass =
          oldClass != null ? classes.getEntity(oldClass.classIndex) : null;
      IndexedMember newMember = convertMember(newLibrary, newClass, oldMember);
      members.register(newMember, data.convert(newMember));
      assert(newMember.memberIndex == oldMember.memberIndex);
      if (newMember.isField) {
        fieldMap[data.node] = newMember;
      } else if (newMember.isConstructor) {
        constructorMap[data.node] = newMember;
      } else {
        methodMap[data.node] = newMember;
      }
    }
    for (int typeVariableIndex = 0;
        typeVariableIndex < _elementMap.typeVariables.length;
        typeVariableIndex++) {
      IndexedTypeVariable oldTypeVariable =
          _elementMap.typeVariables.getEntity(typeVariableIndex);
      KTypeVariableData oldTypeVariableData =
          _elementMap.typeVariables.getData(oldTypeVariable);
      Entity newTypeDeclaration;
      if (oldTypeVariable.typeDeclaration is ClassEntity) {
        IndexedClass cls = oldTypeVariable.typeDeclaration;
        newTypeDeclaration = classes.getEntity(cls.classIndex);
      } else if (oldTypeVariable.typeDeclaration is MemberEntity) {
        IndexedMember member = oldTypeVariable.typeDeclaration;
        newTypeDeclaration = members.getEntity(member.memberIndex);
      } else {
        assert(oldTypeVariable.typeDeclaration is Local);
      }
      IndexedTypeVariable newTypeVariable = createTypeVariable(
          newTypeDeclaration, oldTypeVariable.name, oldTypeVariable.index);
      typeVariableMap[oldTypeVariableData.node] =
          typeVariables.register<IndexedTypeVariable, JTypeVariableData>(
              newTypeVariable, oldTypeVariableData.copy());
      assert(newTypeVariable.typeVariableIndex ==
          oldTypeVariable.typeVariableIndex);
    }
    //typeVariableMap.keys.forEach((n) => print(n.parent));
    // TODO(johnniwinther): We should close the environment in the beginning of
    // this constructor but currently we need the [MemberEntity] to query if the
    // member is live, thus potentially creating the [MemberEntity] in the
    // process. Avoid this.
    _elementMap.envIsClosed = true;
  }

  @override
  void forEachNestedClosure(
      MemberEntity member, void f(FunctionEntity closure)) {
    assert(checkFamily(member));
    _nestedClosureMap[member]?.forEach(f);
  }

  @override
  InterfaceType getMemberThisType(MemberEntity member) {
    return members.getData(member).getMemberThisType(this);
  }

  @override
  ClassTypeVariableAccess getClassTypeVariableAccessForMember(
      MemberEntity member) {
    return members.getData(member).classTypeVariableAccess;
  }

  @override
  bool checkFamily(Entity entity) {
    assert(
        '$entity'.startsWith(jsElementPrefix),
        failedAt(entity,
            "Unexpected entity $entity, expected family $jsElementPrefix."));
    return true;
  }

  @override
  Spannable getSpannable(MemberEntity member, ir.Node node) {
    SourceSpan sourceSpan;
    if (node is ir.TreeNode) {
      sourceSpan = computeSourceSpanFromTreeNode(node);
    }
    sourceSpan ??= getSourceSpan(member, null);
    return sourceSpan;
  }

  @override
  Iterable<LibraryEntity> get libraryListInternal {
    return libraryMap.values;
  }

  @override
  LibraryEntity getLibraryInternal(ir.Library node, [JLibraryEnv env]) {
    LibraryEntity library = libraryMap[node];
    assert(library != null, "No library entity for $node");
    return library;
  }

  @override
  ClassEntity getClassInternal(ir.Class node, [JClassEnv env]) {
    ClassEntity cls = classMap[node];
    assert(cls != null, "No class entity for $node");
    return cls;
  }

  @override
  FieldEntity getFieldInternal(ir.Field node) {
    FieldEntity field = fieldMap[node];
    assert(field != null, "No field entity for $node");
    return field;
  }

  @override
  FunctionEntity getMethodInternal(ir.Procedure node) {
    FunctionEntity function = methodMap[node];
    assert(function != null, "No function entity for $node");
    return function;
  }

  @override
  ConstructorEntity getConstructorInternal(ir.Member node) {
    ConstructorEntity constructor = constructorMap[node];
    assert(constructor != null, "No constructor entity for $node");
    return constructor;
  }

  @override
  TypeVariableEntity getTypeVariableInternal(ir.TypeParameter node) {
    TypeVariableEntity typeVariable = typeVariableMap[node];
    if (typeVariable == null) {
      if (node.parent is ir.FunctionNode) {
        ir.FunctionNode func = node.parent;
        int index = func.typeParameters.indexOf(node);
        if (func.parent is ir.Constructor) {
          ir.Constructor constructor = func.parent;
          ir.Class cls = constructor.enclosingClass;
          typeVariableMap[node] =
              typeVariable = getTypeVariableInternal(cls.typeParameters[index]);
        } else if (func.parent is ir.Procedure) {
          ir.Procedure procedure = func.parent;
          if (procedure.kind == ir.ProcedureKind.Factory) {
            ir.Class cls = procedure.enclosingClass;
            typeVariableMap[node] = typeVariable =
                getTypeVariableInternal(cls.typeParameters[index]);
          }
        }
      }
    }
    assert(
        typeVariable != null,
        "No type variable entity for $node on "
        "${node.parent is ir.FunctionNode ? node.parent.parent : node.parent}");
    return typeVariable;
  }

  @override
  TypedefEntity getTypedefInternal(ir.Typedef node) {
    TypedefEntity typedef = typedefMap[node];
    assert(typedef != null, "No typedef entity for $node");
    return typedef;
  }

  @override
  FunctionEntity getConstructorBody(ir.Constructor node) {
    ConstructorEntity constructor = getConstructor(node);
    return _getConstructorBody(node, constructor);
  }

  FunctionEntity _getConstructorBody(
      ir.Constructor node, covariant IndexedConstructor constructor) {
    JConstructorDataImpl data = members.getData(constructor);
    if (data.constructorBody == null) {
      JConstructorBody constructorBody = createConstructorBody(constructor);
      members.register<IndexedFunction, FunctionData>(
          constructorBody,
          new ConstructorBodyDataImpl(
              node,
              node.function,
              new SpecialMemberDefinition(
                  constructorBody, node, MemberKind.constructorBody)));
      IndexedClass cls = constructor.enclosingClass;
      JClassEnvImpl classEnv = classes.getEnv(cls);
      // TODO(johnniwinther): Avoid this by only including live members in the
      // js-model.
      classEnv.addConstructorBody(constructorBody);
      data.constructorBody = constructorBody;
    }
    return data.constructorBody;
  }

  @override
  JConstructorBody createConstructorBody(ConstructorEntity constructor);

  @override
  MemberDefinition getMemberDefinition(MemberEntity member) {
    return getMemberDefinitionInternal(member);
  }

  @override
  ClassDefinition getClassDefinition(ClassEntity cls) {
    return getClassDefinitionInternal(cls);
  }

  @override
  ConstantValue getFieldConstantValue(covariant IndexedField field) {
    assert(checkFamily(field));
    JFieldData data = members.getData(field);
    return data.getFieldConstantValue(this);
  }

  @override
  bool hasConstantFieldInitializer(covariant IndexedField field) {
    JFieldData data = members.getData(field);
    return data.hasConstantFieldInitializer(this);
  }

  @override
  ConstantValue getConstantFieldInitializer(covariant IndexedField field) {
    JFieldData data = members.getData(field);
    return data.getConstantFieldInitializer(this);
  }

  @override
  void forEachParameter(covariant IndexedFunction function,
      void f(DartType type, String name, ConstantValue defaultValue)) {
    FunctionData data = members.getData(function);
    data.forEachParameter(this, f);
  }

  @override
  void forEachConstructorBody(
      IndexedClass cls, void f(ConstructorBodyEntity member)) {
    JClassEnv env = classes.getEnv(cls);
    env.forEachConstructorBody(f);
  }

  @override
  void forEachInjectedClassMember(
      IndexedClass cls, void f(MemberEntity member)) {
    _injectedClassMembers[cls]?.forEach(f);
  }

  JRecordField _constructRecordFieldEntry(
      InterfaceType memberThisType,
      ir.VariableDeclaration variable,
      BoxLocal boxLocal,
      JClass container,
      Map<String, MemberEntity> memberMap,
      KernelToLocalsMap localsMap) {
    Local local = localsMap.getLocalVariable(variable);
    JRecordField boxedField =
        new JRecordField(local.name, boxLocal, container, variable.isConst);
    members.register(
        boxedField,
        new ClosureFieldData(
            new ClosureMemberDefinition(
                boxedField,
                computeSourceSpanFromTreeNode(variable),
                MemberKind.closureField,
                variable),
            memberThisType));
    memberMap[boxedField.name] = boxedField;

    return boxedField;
  }

  /// Make a container controlling access to records, that is, variables that
  /// are accessed in different scopes. This function creates the container
  /// and returns a map of locals to the corresponding records created.
  @override
  Map<Local, JRecordField> makeRecordContainer(
      KernelScopeInfo info, MemberEntity member, KernelToLocalsMap localsMap) {
    Map<Local, JRecordField> boxedFields = {};
    if (info.boxedVariables.isNotEmpty) {
      NodeBox box = info.capturedVariablesAccessor;

      Map<String, MemberEntity> memberMap = <String, MemberEntity>{};
      JRecord container = new JRecord(member.library, box.name);
      InterfaceType thisType = new InterfaceType(container, const <DartType>[]);
      InterfaceType supertype = commonElements.objectType;
      JClassData containerData = new RecordClassData(
          new ClosureClassDefinition(container,
              computeSourceSpanFromTreeNode(getMemberDefinition(member).node)),
          thisType,
          supertype,
          getOrderedTypeSet(supertype.element).extendClass(thisType));
      classes.register(container, containerData, new RecordEnv(memberMap));

      BoxLocal boxLocal = new BoxLocal(box.name);
      InterfaceType memberThisType = member.enclosingClass != null
          ? elementEnvironment.getThisType(member.enclosingClass)
          : null;
      for (ir.VariableDeclaration variable in info.boxedVariables) {
        boxedFields[localsMap.getLocalVariable(variable)] =
            _constructRecordFieldEntry(memberThisType, variable, boxLocal,
                container, memberMap, localsMap);
      }
    }
    return boxedFields;
  }

  bool _isInRecord(
          Local local, Map<Local, JRecordField> recordFieldsVisibleInScope) =>
      recordFieldsVisibleInScope.containsKey(local);

  KernelClosureClassInfo constructClosureClass(
      MemberEntity member,
      ir.FunctionNode node,
      JLibrary enclosingLibrary,
      Map<Local, JRecordField> recordFieldsVisibleInScope,
      KernelScopeInfo info,
      KernelToLocalsMap localsMap,
      InterfaceType supertype,
      {bool createSignatureMethod}) {
    InterfaceType memberThisType = member.enclosingClass != null
        ? elementEnvironment.getThisType(member.enclosingClass)
        : null;
    ClassTypeVariableAccess typeVariableAccess =
        members.getData(member).classTypeVariableAccess;
    if (typeVariableAccess == ClassTypeVariableAccess.instanceField) {
      // A closure in a field initializer will only be executed in the
      // constructor and type variables are therefore accessed through
      // parameters.
      typeVariableAccess = ClassTypeVariableAccess.parameter;
    }
    String name = _computeClosureName(node);
    SourceSpan location = computeSourceSpanFromTreeNode(node);
    Map<String, MemberEntity> memberMap = <String, MemberEntity>{};

    JClass classEntity = new JClosureClass(enclosingLibrary, name);
    // Create a classData and set up the interfaces and subclass
    // relationships that _ensureSupertypes and _ensureThisAndRawType are doing
    InterfaceType thisType = new InterfaceType(classEntity, const <DartType>[]);
    ClosureClassData closureData = new ClosureClassData(
        new ClosureClassDefinition(classEntity, location),
        thisType,
        supertype,
        getOrderedTypeSet(supertype.element).extendClass(thisType));
    classes.register(classEntity, closureData, new ClosureClassEnv(memberMap));

    Local closureEntity;
    if (node.parent is ir.FunctionDeclaration) {
      ir.FunctionDeclaration parent = node.parent;
      closureEntity = localsMap.getLocalVariable(parent.variable);
    } else if (node.parent is ir.FunctionExpression) {
      closureEntity = new JLocal('', localsMap.currentMember);
    }

    FunctionEntity callMethod = new JClosureCallMethod(
        classEntity, getParameterStructure(node), getAsyncMarker(node));
    _nestedClosureMap
        .putIfAbsent(member, () => <FunctionEntity>[])
        .add(callMethod);
    // We need create the type variable here - before we try to make local
    // variables from them (in `JsScopeInfo.from` called through
    // `KernelClosureClassInfo.fromScopeInfo` below).
    int index = 0;
    for (ir.TypeParameter typeParameter in node.typeParameters) {
      typeVariableMap[typeParameter] = typeVariables.register(
          createTypeVariable(callMethod, typeParameter.name, index),
          new JTypeVariableData(typeParameter));
      index++;
    }

    KernelClosureClassInfo closureClassInfo =
        new KernelClosureClassInfo.fromScopeInfo(
            classEntity,
            node,
            <Local, JRecordField>{},
            info,
            localsMap,
            closureEntity,
            info.hasThisLocal ? new ThisLocal(localsMap.currentMember) : null,
            this);
    _buildClosureClassFields(closureClassInfo, member, memberThisType, info,
        localsMap, recordFieldsVisibleInScope, memberMap);

    if (createSignatureMethod) {
      _constructSignatureMethod(closureClassInfo, memberMap, node,
          memberThisType, location, typeVariableAccess);
    }

    closureData.callType = getFunctionType(node);

    members.register<IndexedFunction, FunctionData>(
        callMethod,
        new ClosureFunctionData(
            new ClosureMemberDefinition(
                callMethod, location, MemberKind.closureCall, node.parent),
            memberThisType,
            closureData.callType,
            node,
            typeVariableAccess));
    memberMap[callMethod.name] = closureClassInfo.callMethod = callMethod;
    return closureClassInfo;
  }

  void _buildClosureClassFields(
      KernelClosureClassInfo closureClassInfo,
      MemberEntity member,
      InterfaceType memberThisType,
      KernelScopeInfo info,
      KernelToLocalsMap localsMap,
      Map<Local, JRecordField> recordFieldsVisibleInScope,
      Map<String, MemberEntity> memberMap) {
    // TODO(efortuna): Limit field number usage to when we need to distinguish
    // between two variables with the same name from different scopes.
    int fieldNumber = 0;

    // For the captured variables that are boxed, ensure this closure has a
    // field to reference the box. This puts the boxes first in the closure like
    // the AST front-end, but otherwise there is no reason to separate this loop
    // from the one below.
    // TODO(redemption): Merge this loop and the following.

    for (ir.Node variable in info.freeVariables) {
      if (variable is ir.VariableDeclaration) {
        Local capturedLocal = localsMap.getLocalVariable(variable);
        if (_isInRecord(capturedLocal, recordFieldsVisibleInScope)) {
          bool constructedField = _constructClosureFieldForRecord(
              capturedLocal,
              closureClassInfo,
              memberThisType,
              memberMap,
              variable,
              recordFieldsVisibleInScope,
              fieldNumber);
          if (constructedField) fieldNumber++;
        }
      }
    }

    // Add a field for the captured 'this'.
    if (info.thisUsedAsFreeVariable) {
      _constructClosureField(
          closureClassInfo.thisLocal,
          closureClassInfo,
          memberThisType,
          memberMap,
          getClassDefinition(member.enclosingClass).node,
          true,
          false,
          fieldNumber);
      fieldNumber++;
    }

    for (ir.Node variable in info.freeVariables) {
      // Make a corresponding field entity in this closure class for the
      // free variables in the KernelScopeInfo.freeVariable.
      if (variable is ir.VariableDeclaration) {
        Local capturedLocal = localsMap.getLocalVariable(variable);
        if (!_isInRecord(capturedLocal, recordFieldsVisibleInScope)) {
          _constructClosureField(
              capturedLocal,
              closureClassInfo,
              memberThisType,
              memberMap,
              variable,
              variable.isConst,
              false, // Closure field is never assigned (only box fields).
              fieldNumber);
          fieldNumber++;
        }
      } else if (variable is TypeVariableTypeWithContext) {
        _constructClosureField(
            localsMap.getLocalTypeVariable(variable.type, this),
            closureClassInfo,
            memberThisType,
            memberMap,
            variable.type.parameter,
            true,
            false,
            fieldNumber);
        fieldNumber++;
      } else {
        throw new UnsupportedError("Unexpected field node type: $variable");
      }
    }
  }

  /// Records point to one or more local variables declared in another scope
  /// that are captured in a scope. Access to those variables goes entirely
  /// through the record container, so we only create a field for the *record*
  /// holding [capturedLocal] and not the individual local variables accessed
  /// through the record. Records, by definition, are not mutable (though the
  /// locals they contain may be). Returns `true` if we constructed a new field
  /// in the closure class.
  bool _constructClosureFieldForRecord(
      Local capturedLocal,
      KernelClosureClassInfo closureClassInfo,
      InterfaceType memberThisType,
      Map<String, MemberEntity> memberMap,
      ir.TreeNode sourceNode,
      Map<Local, JRecordField> recordFieldsVisibleInScope,
      int fieldNumber) {
    JRecordField recordField = recordFieldsVisibleInScope[capturedLocal];

    // Don't construct a new field if the box that holds this local already has
    // a field in the closure class.
    if (closureClassInfo.localToFieldMap.containsKey(recordField.box)) {
      closureClassInfo.boxedVariables[capturedLocal] = recordField;
      return false;
    }

    FieldEntity closureField = new JClosureField(
        '_box_$fieldNumber', closureClassInfo, true, false, recordField.box);

    members.register<IndexedField, JFieldData>(
        closureField,
        new ClosureFieldData(
            new ClosureMemberDefinition(
                closureClassInfo.localToFieldMap[capturedLocal],
                computeSourceSpanFromTreeNode(sourceNode),
                MemberKind.closureField,
                sourceNode),
            memberThisType));
    memberMap[closureField.name] = closureField;
    closureClassInfo.localToFieldMap[recordField.box] = closureField;
    closureClassInfo.boxedVariables[capturedLocal] = recordField;
    return true;
  }

  void _constructSignatureMethod(
      KernelClosureClassInfo closureClassInfo,
      Map<String, MemberEntity> memberMap,
      ir.FunctionNode closureSourceNode,
      InterfaceType memberThisType,
      SourceSpan location,
      ClassTypeVariableAccess typeVariableAccess) {
    FunctionEntity signatureMethod = new JSignatureMethod(
        closureClassInfo.closureClassEntity.library,
        closureClassInfo.closureClassEntity,
        // SignatureMethod takes no arguments.
        const ParameterStructure(0, 0, const [], 0),
        AsyncMarker.SYNC);
    members.register<IndexedFunction, FunctionData>(
        signatureMethod,
        new SignatureFunctionData(
            new SpecialMemberDefinition(signatureMethod,
                closureSourceNode.parent, MemberKind.signature),
            memberThisType,
            null,
            closureSourceNode.typeParameters,
            typeVariableAccess));
    memberMap[signatureMethod.name] =
        closureClassInfo.signatureMethod = signatureMethod;
  }

  void _constructClosureField(
      Local capturedLocal,
      KernelClosureClassInfo closureClassInfo,
      InterfaceType memberThisType,
      Map<String, MemberEntity> memberMap,
      ir.TreeNode sourceNode,
      bool isConst,
      bool isAssignable,
      int fieldNumber) {
    FieldEntity closureField = new JClosureField(
        _getClosureVariableName(capturedLocal.name, fieldNumber),
        closureClassInfo,
        isConst,
        isAssignable,
        capturedLocal);

    members.register<IndexedField, JFieldData>(
        closureField,
        new ClosureFieldData(
            new ClosureMemberDefinition(
                closureClassInfo.localToFieldMap[capturedLocal],
                computeSourceSpanFromTreeNode(sourceNode),
                MemberKind.closureField,
                sourceNode),
            memberThisType));
    memberMap[closureField.name] = closureField;
    closureClassInfo.localToFieldMap[capturedLocal] = closureField;
  }

  // Returns a non-unique name for the given closure element.
  String _computeClosureName(ir.TreeNode treeNode) {
    var parts = <String>[];
    // First anonymous is called 'closure', outer ones called '' to give a
    // compound name where increasing nesting level corresponds to extra
    // underscores.
    var anonymous = 'closure';
    ir.TreeNode current = treeNode;
    // TODO(johnniwinther): Simplify computed names.
    while (current != null) {
      var node = current;
      if (node is ir.FunctionExpression) {
        parts.add(anonymous);
        anonymous = '';
      } else if (node is ir.FunctionDeclaration) {
        String name = node.variable.name;
        if (name != null && name != "") {
          parts.add(utils.operatorNameToIdentifier(name));
        } else {
          parts.add(anonymous);
          anonymous = '';
        }
      } else if (node is ir.Class) {
        // TODO(sra): Do something with abstracted mixin type names like '^#U0'.
        parts.add(node.name);
        break;
      } else if (node is ir.Procedure) {
        if (node.kind == ir.ProcedureKind.Factory) {
          parts.add(utils.reconstructConstructorName(getMember(node)));
        } else {
          parts.add(utils.operatorNameToIdentifier(node.name.name));
        }
      } else if (node is ir.Constructor) {
        parts.add(utils.reconstructConstructorName(getMember(node)));
        break;
      }
      current = current.parent;
    }
    return parts.reversed.join('_');
  }

  /// Generate a unique name for the [id]th closure field, with proposed name
  /// [name].
  ///
  /// The result is used as the name of [ClosureFieldElement]s, and must
  /// therefore be unique to avoid breaking an invariant in the element model
  /// (classes cannot declare multiple fields with the same name).
  ///
  /// Also, the names should be distinct from real field names to prevent
  /// clashes with selectors for those fields.
  ///
  /// These names are not used in generated code, just as element name.
  String _getClosureVariableName(String name, int id) {
    return "_captured_${name}_$id";
  }

  @override
  JGeneratorBody getGeneratorBody(covariant IndexedFunction function) {
    JGeneratorBody generatorBody = _generatorBodies[function];
    if (generatorBody == null) {
      FunctionData functionData = members.getData(function);
      ir.TreeNode node = functionData.definition.node;
      DartType elementType =
          elementEnvironment.getFunctionAsyncOrSyncStarElementType(function);
      generatorBody = createGeneratorBody(function, elementType);
      members.register<IndexedFunction, FunctionData>(
          generatorBody,
          new GeneratorBodyFunctionData(
              functionData,
              new SpecialMemberDefinition(
                  generatorBody, node, MemberKind.generatorBody)));

      if (function.enclosingClass != null) {
        // TODO(sra): Integrate this with ClassEnvImpl.addConstructorBody ?
        (_injectedClassMembers[function.enclosingClass] ??= <MemberEntity>[])
            .add(generatorBody);
      }
    }
    return generatorBody;
  }

  @override
  JGeneratorBody createGeneratorBody(
      FunctionEntity function, DartType elementType);

  @override
  js.Template getJsBuiltinTemplate(
      ConstantValue constant, CodeEmitterTask emitter) {
    int index = extractEnumIndexFromConstantValue(
        constant, commonElements.jsBuiltinEnum);
    if (index == null) return null;
    return emitter.builtinTemplateFor(JsBuiltin.values[index]);
  }
}

class JsToFrontendMapImpl extends JsToFrontendMapBase
    implements JsToFrontendMap {
  final JsToElementMapBase _backend;

  JsToFrontendMapImpl(this._backend);

  LibraryEntity toBackendLibrary(covariant IndexedLibrary library) {
    return _backend.libraries.getEntity(library.libraryIndex);
  }

  ClassEntity toBackendClass(covariant IndexedClass cls) {
    return _backend.classes.getEntity(cls.classIndex);
  }

  MemberEntity toBackendMember(covariant IndexedMember member) {
    return _backend.members.getEntity(member.memberIndex);
  }

  TypedefEntity toBackendTypedef(covariant IndexedTypedef typedef) {
    return _backend.typedefs.getEntity(typedef.typedefIndex);
  }

  TypeVariableEntity toBackendTypeVariable(TypeVariableEntity typeVariable) {
    if (typeVariable is KLocalTypeVariable) {
      failedAt(
          typeVariable, "Local function type variables are not supported.");
    }
    IndexedTypeVariable indexedTypeVariable = typeVariable;
    return _backend.typeVariables
        .getEntity(indexedTypeVariable.typeVariableIndex);
  }
}
