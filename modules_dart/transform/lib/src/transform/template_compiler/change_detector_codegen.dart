library angular2.transform.template_compiler.change_detector_codegen;

import 'package:angular2/src/core/change_detection/change_detection.dart';
import 'package:angular2/src/core/change_detection/change_detection_util.dart';
import 'package:angular2/src/core/change_detection/codegen_facade.dart';
import 'package:angular2/src/core/change_detection/codegen_logic_util.dart';
import 'package:angular2/src/core/change_detection/codegen_name_util.dart';
import 'package:angular2/src/core/change_detection/directive_record.dart';
import 'package:angular2/src/core/change_detection/interfaces.dart';
import 'package:angular2/src/core/change_detection/proto_change_detector.dart';
import 'package:angular2/src/core/change_detection/proto_record.dart';
import 'package:angular2/src/core/change_detection/event_binding.dart';
import 'package:angular2/src/core/change_detection/binding_record.dart';
import 'package:angular2/src/core/change_detection/codegen_facade.dart' show codify;
import 'package:angular2/src/core/facade/lang.dart' show BaseException;

/// Responsible for generating change detector classes for Angular 2.
///
/// This code should be kept in sync with the `ChangeDetectorJITGenerator`
/// class. If you make updates here, please make equivalent changes there.
class Codegen {
  /// Stores the generated class definitions.
  final StringBuffer _buf = new StringBuffer();

  /// Stores all generated initialization code.
  final StringBuffer _initBuf = new StringBuffer();

  /// The names of already generated classes.
  final Set<String> _names = new Set<String>();

  /// Generates a change detector class with name `changeDetectorTypeName`,
  /// which must not conflict with other generated classes in the same
  /// `.ng_deps.dart` file.  The change detector is used to detect changes in
  /// Objects of type `typeName`.
  void generate(String typeName, String changeDetectorTypeName,
      ChangeDetectorDefinition def) {
    if (_names.contains(changeDetectorTypeName)) {
      throw new BaseException(
          'Change detector named "${changeDetectorTypeName}" for ${typeName} '
          'conflicts with an earlier generated change detector class.');
    }
    _names.add(changeDetectorTypeName);
    new _CodegenState(typeName, changeDetectorTypeName, def)
      .._writeToBuf(_buf)
      .._writeInitToBuf(_initBuf);
  }

  /// Gets all imports necessary for the generated code.
  String get imports {
    return _buf.isEmpty
        ? ''
        : '''import '$_PREGEN_PROTO_CHANGE_DETECTOR_IMPORT' as $_GEN_PREFIX;''';
  }

  bool get isEmpty => _buf.isEmpty;

  /// Gets the initilization code that registers the generated classes with
  /// the Angular 2 change detection system.
  String get initialize => '$_initBuf';

  @override
  String toString() => '$_buf';
}

/// The state needed to generate a change detector for a single `Component`.
class _CodegenState {
  /// The `id` of the `ChangeDetectorDefinition` we are generating this class
  /// for.
  final String _changeDetectorDefId;

  /// The name of the `Type` this change detector is generated for. For example,
  /// this is `MyComponent` if the generated class will detect changes in
  /// `MyComponent` objects.
  final String _contextTypeName;

  /// The name of the generated change detector class. This is an implementation
  /// detail and should not be visible to users.
  final String _changeDetectorTypeName;
  final ChangeDetectionStrategy _changeDetectionStrategy;
  final List<DirectiveRecord> _directiveRecords;
  final List<ProtoRecord> _records;
  final List<EventBinding> _eventBindings;
  final CodegenLogicUtil _logic;
  final CodegenNameUtil _names;
  final ChangeDetectorGenConfig _genConfig;
  final List<BindingTarget> _propertyBindingTargets;

  String get _changeDetectionStrategyAsCode =>
    _changeDetectionStrategy == null ? 'null' : '${_GEN_PREFIX}.${_changeDetectionStrategy}';

  _CodegenState._(
      this._changeDetectorDefId,
      this._contextTypeName,
      this._changeDetectorTypeName,
      this._changeDetectionStrategy,
      this._records,
      this._propertyBindingTargets,
      this._eventBindings,
      this._directiveRecords,
      this._logic,
      this._names,
      this._genConfig);

  factory _CodegenState(String typeName, String changeDetectorTypeName,
      ChangeDetectorDefinition def) {
    var protoRecords = createPropertyRecords(def);
    var eventBindings = createEventRecords(def);
    var propertyBindingTargets = def.bindingRecords.map((b) => b.target).toList();

    var names = new CodegenNameUtil(protoRecords, eventBindings, def.directiveRecords, _UTIL);
    var logic = new CodegenLogicUtil(names, _UTIL, def.strategy);
    return new _CodegenState._(
        def.id,
        typeName,
        changeDetectorTypeName,
        def.strategy,
        protoRecords,
        propertyBindingTargets,
        eventBindings,
        def.directiveRecords,
        logic,
        names,
        def.genConfig);
  }

  void _writeToBuf(StringBuffer buf) {
    buf.write('''\n
      class $_changeDetectorTypeName extends $_BASE_CLASS<$_contextTypeName> {
        ${_genDeclareFields()}

        $_changeDetectorTypeName(dispatcher)
          : super(${codify(_changeDetectorDefId)},
              dispatcher, ${_records.length},
              ${_changeDetectorTypeName}.gen_propertyBindingTargets,
              ${_changeDetectorTypeName}.gen_directiveIndices,
              ${_changeDetectionStrategyAsCode}) {
          dehydrateDirectives(false);
        }

        void detectChangesInRecordsInternal(throwOnChange) {
          ${_names.genInitLocals()}
          var $_IS_CHANGED_LOCAL = false;
          var $_CHANGES_LOCAL = null;

          ${_records.map(_genRecord).join('')}
        }

        ${_maybeGenHandleEventInternal()}

        ${_genCheckNoChanges()}

        ${_maybeGenAfterContentLifecycleCallbacks()}

        ${_maybeGenAfterViewLifecycleCallbacks()}

        ${_maybeGenHydrateDirectives()}

        ${_maybeGenDehydrateDirectives()}

        ${_genPropertyBindingTargets()};

        ${_genDirectiveIndices()};

        static $_GEN_PREFIX.ProtoChangeDetector
            $PROTO_CHANGE_DETECTOR_FACTORY_METHOD(
            $_GEN_PREFIX.ChangeDetectorDefinition def) {
          return new $_GEN_PREFIX.PregenProtoChangeDetector(
              (a) => new $_changeDetectorTypeName(a),
              def);
        }
      }
    ''');
  }

  String _genPropertyBindingTargets() {
    var targets = _logic.genPropertyBindingTargets(_propertyBindingTargets, this._genConfig.genDebugInfo);
    return "static var gen_propertyBindingTargets = ${targets}";
  }

  String _genDirectiveIndices() {
    var indices = _logic.genDirectiveIndices(_directiveRecords);
    return "static var gen_directiveIndices = ${indices}";
  }

  String _maybeGenHandleEventInternal() {
    if (_eventBindings.length > 0) {
      var handlers = _eventBindings.map((eb) => _genEventBinding(eb)).join("\n");
      return '''
        handleEventInternal(eventName, elIndex, locals) {
          var ${this._names.getPreventDefaultAccesor()} = false;
          ${this._names.genInitEventLocals()}
          ${handlers}
          return ${this._names.getPreventDefaultAccesor()};
        }
      ''';
    } else {
      return '';
    }
  }

  String _genEventBinding(EventBinding eb) {
    var recs = eb.records.map((r) => _genEventBindingEval(eb, r)).join("\n");
    return '''
    if (eventName == "${eb.eventName}" && elIndex == ${eb.elIndex}) {
    ${recs}
    }''';
  }

  String _genEventBindingEval(EventBinding eb, ProtoRecord r){
    if (r.lastInBinding) {
      var evalRecord = _logic.genEventBindingEvalValue(eb, r);
      var markPath = _genMarkPathToRootAsCheckOnce(r);
      var prevDefault = _genUpdatePreventDefault(eb, r);
      return "${evalRecord}\n${markPath}\n${prevDefault}";
    } else {
      return _logic.genEventBindingEvalValue(eb, r);
    }
  }

  String _genMarkPathToRootAsCheckOnce(ProtoRecord r) {
    var br = r.bindingRecord;
    if (!br.isDefaultChangeDetection()) {
      return "${_names.getDetectorName(br.directiveRecord.directiveIndex)}.markPathToRootAsCheckOnce();";
    } else {
      return "";
    }
  }

  String _genUpdatePreventDefault(EventBinding eb, ProtoRecord r) {
    var local = this._names.getEventLocalName(eb, r.selfIndex);
    return """if (${local} == false) { ${_names.getPreventDefaultAccesor()} = true; }""";
  }

  void _writeInitToBuf(StringBuffer buf) {
    buf.write('''
      $_GEN_PREFIX.preGeneratedProtoDetectors['$_changeDetectorDefId'] =
          $_changeDetectorTypeName.newProtoChangeDetector;
    ''');
  }

  String _maybeGenDehydrateDirectives() {
    var destroyPipesParamName = 'destroyPipes';
    var destroyPipesCode = _names.genPipeOnDestroy();
    if (destroyPipesCode.isNotEmpty) {
      destroyPipesCode = 'if (${destroyPipesParamName}) {${destroyPipesCode}}';
    }
    var dehydrateFieldsCode = _names.genDehydrateFields();
    if (destroyPipesCode.isEmpty && dehydrateFieldsCode.isEmpty) return '';
    return 'void dehydrateDirectives(${destroyPipesParamName}) '
        '{ ${destroyPipesCode} ${dehydrateFieldsCode} }';
  }

  String _maybeGenHydrateDirectives() {
    var hydrateDirectivesCode = _logic.genHydrateDirectives(_directiveRecords);
    var hydrateDetectorsCode = _logic.genHydrateDetectors(_directiveRecords);
    if (hydrateDirectivesCode.isEmpty && hydrateDetectorsCode.isEmpty) {
      return '';
    }
    return 'void hydrateDirectives(directives) '
        '{ $hydrateDirectivesCode $hydrateDetectorsCode }';
  }

  String _maybeGenAfterContentLifecycleCallbacks() {
    var directiveNotifications = _logic.genContentLifecycleCallbacks(_directiveRecords);
    if (directiveNotifications.isNotEmpty) {
      return '''
        void afterContentLifecycleCallbacksInternal() {
          ${directiveNotifications.join('')}
        }
      ''';
    } else {
      return '';
    }
  }

  String _maybeGenAfterViewLifecycleCallbacks() {
    var directiveNotifications = _logic.genViewLifecycleCallbacks(_directiveRecords);
    if (directiveNotifications.isNotEmpty) {
      return '''
        void afterViewLifecycleCallbacksInternal() {
          ${directiveNotifications.join('')}
        }
      ''';
    } else {
      return '';
    }
  }

  String _genDeclareFields() {
    var fields = _names.getAllFieldNames();
    // If there's only one field, it's `context`, declared in the superclass.
    if (fields.length == 1) return '';
    fields.removeAt(CONTEXT_INDEX);
    var toRemove = 'this.';
    var declareNames = fields
        .map((f) => f.startsWith(toRemove) ? f.substring(toRemove.length) : f);
    return 'var ${declareNames.join(', ')};';
  }

  String _genRecord(ProtoRecord r) {
    var rec = null;
    if (r.isLifeCycleRecord()) {
      rec = _genDirectiveLifecycle(r);
    } else if (r.isPipeRecord()) {
      rec = _genPipeCheck(r);
    } else {
      rec = _genReferenceCheck(r);
    }
    return '''
      ${this._maybeFirstInBinding(r)}
      ${rec}
      ${this._maybeGenLastInDirective(r)}
    ''';
  }

  String _genDirectiveLifecycle(ProtoRecord r) {
    if (r.name == 'DoCheck') {
      return _genDoCheck(r);
    } else if (r.name == 'OnInit') {
      return _genOnInit(r);
    } else if (r.name == 'OnChanges') {
      return _genOnChanges(r);
    } else {
      throw new BaseException("Unknown lifecycle event '${r.name}'");
    }
  }

  String _genPipeCheck(ProtoRecord r) {
    var context = _names.getLocalName(r.contextIndex);
    var argString = r.args.map((arg) => _names.getLocalName(arg)).join(", ");

    var oldValue = _names.getFieldName(r.selfIndex);
    var newValue = _names.getLocalName(r.selfIndex);

    var pipe = _names.getPipeName(r.selfIndex);
    var pipeType = r.name;

    var init = '''
      if ($_IDENTICAL_CHECK_FN($pipe, $_UTIL.uninitialized)) {
        $pipe = ${_names.getPipesAccessorName()}.get('$pipeType');
      }
    ''';

    var read = '''
      $newValue = $pipe.pipe.transform($context, [$argString]);
    ''';

    var contexOrArgCheck = r.args.map((a) => _names.getChangeName(a)).toList();
    contexOrArgCheck.add(_names.getChangeName(r.contextIndex));
    var condition = '''!${pipe}.pure || (${contexOrArgCheck.join(" || ")})''';

    var check = '''
      if ($_NOT_IDENTICAL_CHECK_FN($oldValue, $newValue)) {
        $newValue = $_UTIL.unwrapValue($newValue);
        ${_genChangeMarker(r)}
        ${_genUpdateDirectiveOrElement(r)}
        ${_genAddToChanges(r)}
        $oldValue = $newValue;
      }
    ''';

    var genCode = r.shouldBeChecked() ? '''${read}${check}''' : read;

    if (r.isUsedByOtherRecord()) {
      return '''${init} if (${condition}) { ${genCode} } else { ${newValue} = ${oldValue}; }''';
    } else {
      return '''${init} if (${condition}) { ${genCode} }''';
    }
  }

  String _genReferenceCheck(ProtoRecord r) {
    var oldValue = _names.getFieldName(r.selfIndex);
    var newValue = _names.getLocalName(r.selfIndex);
    var read = '''
      ${_logic.genPropertyBindingEvalValue(r)}
    ''';

    var check = '''
      if ($_NOT_IDENTICAL_CHECK_FN($newValue, $oldValue)) {
        ${_genChangeMarker(r)}
        ${_genUpdateDirectiveOrElement(r)}
        ${_genAddToChanges(r)}
        $oldValue = $newValue;
      }
    ''';

    var genCode = r.shouldBeChecked() ? "${read}${check}" : read;

    if (r.isPureFunction()) {
      // Add an "if changed guard"
      var condition = r.args.map((a) => _names.getChangeName(a)).join(' || ');
      if (r.isUsedByOtherRecord()) {
        return 'if ($condition) { $genCode } else { $newValue = $oldValue; }';
      } else {
        return 'if ($condition) { $genCode }';
      }
    } else {
      return genCode;
    }
  }

  String _genChangeMarker(ProtoRecord r) {
    return r.argumentToPureFunction
        ? "${this._names.getChangeName(r.selfIndex)} = true;"
        : "";
  }

  String _genUpdateDirectiveOrElement(ProtoRecord r) {
    if (!r.lastInBinding) return '';

    var newValue = _names.getLocalName(r.selfIndex);
    var oldValue = _names.getFieldName(r.selfIndex);
    var notifyDebug = _genConfig.logBindingUpdate ? "this.logBindingUpdate(${newValue});" : "";

    var br = r.bindingRecord;
    if (br.target.isDirective()) {
      var directiveProperty =
          '${_names.getDirectiveName(br.directiveRecord.directiveIndex)}.${br.target.name}';
      return '''
      ${_genThrowOnChangeCheck(oldValue, newValue)}
      $directiveProperty = $newValue;
      ${notifyDebug}
      $_IS_CHANGED_LOCAL = true;
    ''';
    } else {
      return '''
      ${_genThrowOnChangeCheck(oldValue, newValue)}
      this.notifyDispatcher(${newValue});
      ${notifyDebug}
    ''';
    }
  }

  String _genThrowOnChangeCheck(String oldValue, String newValue) {
    if (this._genConfig.genCheckNoChanges) {
      return '''
        if(throwOnChange) {
          this.throwOnChangeError(${oldValue}, ${newValue});
        }
      ''';
    } else {
      return "";
    }
  }

  String _genCheckNoChanges() {
    if (this._genConfig.genCheckNoChanges) {
      return 'void checkNoChanges() { runDetectChanges(true); }';
    } else {
      return '';
    }
  }

  String _maybeFirstInBinding(ProtoRecord r) {
    var prev = ChangeDetectionUtil.protoByIndex(_records, r.selfIndex - 1);
    var firstInBindng = prev == null || prev.bindingRecord != r.bindingRecord;
    return firstInBindng && !r.bindingRecord.isDirectiveLifecycle()
        ? "${_names.getPropertyBindingIndex()} = ${r.propertyBindingIndex};"
        : '';
  }

  String _genAddToChanges(ProtoRecord r) {
    var newValue = _names.getLocalName(r.selfIndex);
    var oldValue = _names.getFieldName(r.selfIndex);
    if (!r.bindingRecord.callOnChanges()) return '';
    return "$_CHANGES_LOCAL = addChange($_CHANGES_LOCAL, $oldValue, $newValue);";
  }

  String _maybeGenLastInDirective(ProtoRecord r) {
    if (!r.lastInDirective) return '';
    return '''
      $_CHANGES_LOCAL = null;
      ${_genNotifyOnPushDetectors(r)}
      $_IS_CHANGED_LOCAL = false;
    ''';
  }

  String _genDoCheck(ProtoRecord r) {
    var br = r.bindingRecord;
    return 'if (!throwOnChange) '
        '${_names.getDirectiveName(br.directiveRecord.directiveIndex)}.doCheck();';
  }

  String _genOnInit(ProtoRecord r) {
    var br = r.bindingRecord;
    return 'if (!throwOnChange && !${_names.getAlreadyCheckedName()}) '
        '${_names.getDirectiveName(br.directiveRecord.directiveIndex)}.onInit();';
  }

  String _genOnChanges(ProtoRecord r) {
    var br = r.bindingRecord;
    return 'if (!throwOnChange && $_CHANGES_LOCAL != null) '
        '${_names.getDirectiveName(br.directiveRecord.directiveIndex)}'
        '.onChanges($_CHANGES_LOCAL);';
  }

  String _genNotifyOnPushDetectors(ProtoRecord r) {
    var br = r.bindingRecord;
    if (!r.lastInDirective || br.isDefaultChangeDetection()) return '';
    return '''
      if($_IS_CHANGED_LOCAL) {
        ${_names.getDetectorName(br.directiveRecord.directiveIndex)}.markAsCheckOnce();
      }
    ''';
  }
}

const PROTO_CHANGE_DETECTOR_FACTORY_METHOD = 'newProtoChangeDetector';

const _BASE_CLASS = '$_GEN_PREFIX.AbstractChangeDetector';
const _CHANGES_LOCAL = 'changes';
const _GEN_PREFIX = '_gen';
const _GEN_RECORDS_METHOD_NAME = '_createRecords';
const _IDENTICAL_CHECK_FN = '$_GEN_PREFIX.looseIdentical';
const _NOT_IDENTICAL_CHECK_FN = '$_GEN_PREFIX.looseNotIdentical';
const _IS_CHANGED_LOCAL = 'isChanged';
const _PREGEN_PROTO_CHANGE_DETECTOR_IMPORT =
    'package:angular2/src/core/change_detection/pregen_proto_change_detector.dart';
const _UTIL = '$_GEN_PREFIX.ChangeDetectionUtil';
