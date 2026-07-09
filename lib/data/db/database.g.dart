// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $TrackPointsTable extends TrackPoints
    with TableInfo<$TrackPointsTable, TrackPoint> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrackPointsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _lngMeta = const VerificationMeta('lng');
  @override
  late final GeneratedColumn<double> lng = GeneratedColumn<double>(
      'lng', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<DateTime> time = GeneratedColumn<DateTime>(
      'time', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _accuracyMeta =
      const VerificationMeta('accuracy');
  @override
  late final GeneratedColumn<double> accuracy = GeneratedColumn<double>(
      'accuracy', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _altitudeMeta =
      const VerificationMeta('altitude');
  @override
  late final GeneratedColumn<double> altitude = GeneratedColumn<double>(
      'altitude', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _speedMeta = const VerificationMeta('speed');
  @override
  late final GeneratedColumn<double> speed = GeneratedColumn<double>(
      'speed', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<double> width = GeneratedColumn<double>(
      'width', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _layerIdMeta =
      const VerificationMeta('layerId');
  @override
  late final GeneratedColumn<int> layerId = GeneratedColumn<int>(
      'layer_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [id, uuid, lat, lng, time, accuracy, altitude, speed, width, layerId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'track_points';
  @override
  VerificationContext validateIntegrity(Insertable<TrackPoint> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    } else if (isInserting) {
      context.missing(_latMeta);
    }
    if (data.containsKey('lng')) {
      context.handle(
          _lngMeta, lng.isAcceptableOrUnknown(data['lng']!, _lngMeta));
    } else if (isInserting) {
      context.missing(_lngMeta);
    }
    if (data.containsKey('time')) {
      context.handle(
          _timeMeta, time.isAcceptableOrUnknown(data['time']!, _timeMeta));
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('accuracy')) {
      context.handle(_accuracyMeta,
          accuracy.isAcceptableOrUnknown(data['accuracy']!, _accuracyMeta));
    }
    if (data.containsKey('altitude')) {
      context.handle(_altitudeMeta,
          altitude.isAcceptableOrUnknown(data['altitude']!, _altitudeMeta));
    }
    if (data.containsKey('speed')) {
      context.handle(
          _speedMeta, speed.isAcceptableOrUnknown(data['speed']!, _speedMeta));
    }
    if (data.containsKey('width')) {
      context.handle(
          _widthMeta, width.isAcceptableOrUnknown(data['width']!, _widthMeta));
    }
    if (data.containsKey('layer_id')) {
      context.handle(_layerIdMeta,
          layerId.isAcceptableOrUnknown(data['layer_id']!, _layerIdMeta));
    } else if (isInserting) {
      context.missing(_layerIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrackPoint map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackPoint(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat'])!,
      lng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lng'])!,
      time: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}time'])!,
      accuracy: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}accuracy']),
      altitude: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}altitude']),
      speed: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}speed']),
      width: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}width']),
      layerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}layer_id'])!,
    );
  }

  @override
  $TrackPointsTable createAlias(String alias) {
    return $TrackPointsTable(attachedDatabase, alias);
  }
}

class TrackPoint extends DataClass implements Insertable<TrackPoint> {
  final int id;

  /// Stable cross-device identity. Used by backup import to skip rows we
  /// already have. Auto-populated on insert when callers don't provide one.
  final String uuid;
  final double lat;
  final double lng;
  final DateTime time;
  final double? accuracy;
  final double? altitude;
  final double? speed;

  /// Visible trail/point size (full corridor width, in metres) captured at
  /// record time. Stored per-point so changing the size setting only
  /// affects *new* points — historical trails keep the width they were
  /// recorded with. Null on rows predating this column → rendered at the
  /// renderer's default width.
  final double? width;
  final int layerId;
  const TrackPoint(
      {required this.id,
      required this.uuid,
      required this.lat,
      required this.lng,
      required this.time,
      this.accuracy,
      this.altitude,
      this.speed,
      this.width,
      required this.layerId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['lat'] = Variable<double>(lat);
    map['lng'] = Variable<double>(lng);
    map['time'] = Variable<DateTime>(time);
    if (!nullToAbsent || accuracy != null) {
      map['accuracy'] = Variable<double>(accuracy);
    }
    if (!nullToAbsent || altitude != null) {
      map['altitude'] = Variable<double>(altitude);
    }
    if (!nullToAbsent || speed != null) {
      map['speed'] = Variable<double>(speed);
    }
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<double>(width);
    }
    map['layer_id'] = Variable<int>(layerId);
    return map;
  }

  TrackPointsCompanion toCompanion(bool nullToAbsent) {
    return TrackPointsCompanion(
      id: Value(id),
      uuid: Value(uuid),
      lat: Value(lat),
      lng: Value(lng),
      time: Value(time),
      accuracy: accuracy == null && nullToAbsent
          ? const Value.absent()
          : Value(accuracy),
      altitude: altitude == null && nullToAbsent
          ? const Value.absent()
          : Value(altitude),
      speed:
          speed == null && nullToAbsent ? const Value.absent() : Value(speed),
      width:
          width == null && nullToAbsent ? const Value.absent() : Value(width),
      layerId: Value(layerId),
    );
  }

  factory TrackPoint.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackPoint(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      lat: serializer.fromJson<double>(json['lat']),
      lng: serializer.fromJson<double>(json['lng']),
      time: serializer.fromJson<DateTime>(json['time']),
      accuracy: serializer.fromJson<double?>(json['accuracy']),
      altitude: serializer.fromJson<double?>(json['altitude']),
      speed: serializer.fromJson<double?>(json['speed']),
      width: serializer.fromJson<double?>(json['width']),
      layerId: serializer.fromJson<int>(json['layerId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'lat': serializer.toJson<double>(lat),
      'lng': serializer.toJson<double>(lng),
      'time': serializer.toJson<DateTime>(time),
      'accuracy': serializer.toJson<double?>(accuracy),
      'altitude': serializer.toJson<double?>(altitude),
      'speed': serializer.toJson<double?>(speed),
      'width': serializer.toJson<double?>(width),
      'layerId': serializer.toJson<int>(layerId),
    };
  }

  TrackPoint copyWith(
          {int? id,
          String? uuid,
          double? lat,
          double? lng,
          DateTime? time,
          Value<double?> accuracy = const Value.absent(),
          Value<double?> altitude = const Value.absent(),
          Value<double?> speed = const Value.absent(),
          Value<double?> width = const Value.absent(),
          int? layerId}) =>
      TrackPoint(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        time: time ?? this.time,
        accuracy: accuracy.present ? accuracy.value : this.accuracy,
        altitude: altitude.present ? altitude.value : this.altitude,
        speed: speed.present ? speed.value : this.speed,
        width: width.present ? width.value : this.width,
        layerId: layerId ?? this.layerId,
      );
  TrackPoint copyWithCompanion(TrackPointsCompanion data) {
    return TrackPoint(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      lat: data.lat.present ? data.lat.value : this.lat,
      lng: data.lng.present ? data.lng.value : this.lng,
      time: data.time.present ? data.time.value : this.time,
      accuracy: data.accuracy.present ? data.accuracy.value : this.accuracy,
      altitude: data.altitude.present ? data.altitude.value : this.altitude,
      speed: data.speed.present ? data.speed.value : this.speed,
      width: data.width.present ? data.width.value : this.width,
      layerId: data.layerId.present ? data.layerId.value : this.layerId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackPoint(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('time: $time, ')
          ..write('accuracy: $accuracy, ')
          ..write('altitude: $altitude, ')
          ..write('speed: $speed, ')
          ..write('width: $width, ')
          ..write('layerId: $layerId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, uuid, lat, lng, time, accuracy, altitude, speed, width, layerId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackPoint &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.lat == this.lat &&
          other.lng == this.lng &&
          other.time == this.time &&
          other.accuracy == this.accuracy &&
          other.altitude == this.altitude &&
          other.speed == this.speed &&
          other.width == this.width &&
          other.layerId == this.layerId);
}

class TrackPointsCompanion extends UpdateCompanion<TrackPoint> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<double> lat;
  final Value<double> lng;
  final Value<DateTime> time;
  final Value<double?> accuracy;
  final Value<double?> altitude;
  final Value<double?> speed;
  final Value<double?> width;
  final Value<int> layerId;
  const TrackPointsCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.lat = const Value.absent(),
    this.lng = const Value.absent(),
    this.time = const Value.absent(),
    this.accuracy = const Value.absent(),
    this.altitude = const Value.absent(),
    this.speed = const Value.absent(),
    this.width = const Value.absent(),
    this.layerId = const Value.absent(),
  });
  TrackPointsCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required double lat,
    required double lng,
    required DateTime time,
    this.accuracy = const Value.absent(),
    this.altitude = const Value.absent(),
    this.speed = const Value.absent(),
    this.width = const Value.absent(),
    required int layerId,
  })  : lat = Value(lat),
        lng = Value(lng),
        time = Value(time),
        layerId = Value(layerId);
  static Insertable<TrackPoint> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<double>? lat,
    Expression<double>? lng,
    Expression<DateTime>? time,
    Expression<double>? accuracy,
    Expression<double>? altitude,
    Expression<double>? speed,
    Expression<double>? width,
    Expression<int>? layerId,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (time != null) 'time': time,
      if (accuracy != null) 'accuracy': accuracy,
      if (altitude != null) 'altitude': altitude,
      if (speed != null) 'speed': speed,
      if (width != null) 'width': width,
      if (layerId != null) 'layer_id': layerId,
    });
  }

  TrackPointsCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<double>? lat,
      Value<double>? lng,
      Value<DateTime>? time,
      Value<double?>? accuracy,
      Value<double?>? altitude,
      Value<double?>? speed,
      Value<double?>? width,
      Value<int>? layerId}) {
    return TrackPointsCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      time: time ?? this.time,
      accuracy: accuracy ?? this.accuracy,
      altitude: altitude ?? this.altitude,
      speed: speed ?? this.speed,
      width: width ?? this.width,
      layerId: layerId ?? this.layerId,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lng.present) {
      map['lng'] = Variable<double>(lng.value);
    }
    if (time.present) {
      map['time'] = Variable<DateTime>(time.value);
    }
    if (accuracy.present) {
      map['accuracy'] = Variable<double>(accuracy.value);
    }
    if (altitude.present) {
      map['altitude'] = Variable<double>(altitude.value);
    }
    if (speed.present) {
      map['speed'] = Variable<double>(speed.value);
    }
    if (width.present) {
      map['width'] = Variable<double>(width.value);
    }
    if (layerId.present) {
      map['layer_id'] = Variable<int>(layerId.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrackPointsCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('time: $time, ')
          ..write('accuracy: $accuracy, ')
          ..write('altitude: $altitude, ')
          ..write('speed: $speed, ')
          ..write('width: $width, ')
          ..write('layerId: $layerId')
          ..write(')'))
        .toString();
  }
}

class $TrackLayersTable extends TrackLayers
    with TableInfo<$TrackLayersTable, TrackLayer> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TrackLayersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
      'name', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _colorValueMeta =
      const VerificationMeta('colorValue');
  @override
  late final GeneratedColumn<int> colorValue = GeneratedColumn<int>(
      'color_value', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _visibleMeta =
      const VerificationMeta('visible');
  @override
  late final GeneratedColumn<bool> visible = GeneratedColumn<bool>(
      'visible', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("visible" IN (0, 1))'),
      defaultValue: const Constant(true));
  static const VerificationMeta _tagMeta = const VerificationMeta('tag');
  @override
  late final GeneratedColumn<String> tag = GeneratedColumn<String>(
      'tag', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _createdAtMeta =
      const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
      'created_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _pathColorMeta =
      const VerificationMeta('pathColor');
  @override
  late final GeneratedColumn<int> pathColor = GeneratedColumn<int>(
      'path_color', aliasedName, true,
      type: DriftSqlType.int, requiredDuringInsert: false);
  static const VerificationMeta _pathOpacityMeta =
      const VerificationMeta('pathOpacity');
  @override
  late final GeneratedColumn<double> pathOpacity = GeneratedColumn<double>(
      'path_opacity', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _pathWidthMeta =
      const VerificationMeta('pathWidth');
  @override
  late final GeneratedColumn<double> pathWidth = GeneratedColumn<double>(
      'path_width', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uuid,
        name,
        colorValue,
        visible,
        tag,
        createdAt,
        pathColor,
        pathOpacity,
        pathWidth,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'track_layers';
  @override
  VerificationContext validateIntegrity(Insertable<TrackLayer> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
          _nameMeta, name.isAcceptableOrUnknown(data['name']!, _nameMeta));
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('color_value')) {
      context.handle(
          _colorValueMeta,
          colorValue.isAcceptableOrUnknown(
              data['color_value']!, _colorValueMeta));
    } else if (isInserting) {
      context.missing(_colorValueMeta);
    }
    if (data.containsKey('visible')) {
      context.handle(_visibleMeta,
          visible.isAcceptableOrUnknown(data['visible']!, _visibleMeta));
    }
    if (data.containsKey('tag')) {
      context.handle(
          _tagMeta, tag.isAcceptableOrUnknown(data['tag']!, _tagMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta,
          createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('path_color')) {
      context.handle(_pathColorMeta,
          pathColor.isAcceptableOrUnknown(data['path_color']!, _pathColorMeta));
    }
    if (data.containsKey('path_opacity')) {
      context.handle(
          _pathOpacityMeta,
          pathOpacity.isAcceptableOrUnknown(
              data['path_opacity']!, _pathOpacityMeta));
    }
    if (data.containsKey('path_width')) {
      context.handle(_pathWidthMeta,
          pathWidth.isAcceptableOrUnknown(data['path_width']!, _pathWidthMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  TrackLayer map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return TrackLayer(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      name: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}name'])!,
      colorValue: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}color_value'])!,
      visible: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}visible'])!,
      tag: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tag']),
      createdAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      pathColor: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}path_color']),
      pathOpacity: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}path_opacity']),
      pathWidth: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}path_width']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $TrackLayersTable createAlias(String alias) {
    return $TrackLayersTable(attachedDatabase, alias);
  }
}

class TrackLayer extends DataClass implements Insertable<TrackLayer> {
  final int id;
  final String uuid;
  final String name;
  final int colorValue;
  final bool visible;
  final String? tag;
  final DateTime createdAt;

  /// Per-layer path/fog style. All nullable — null means "inherit the
  /// global default" (settings.fogColor / fogOpacity / trailWidth), so
  /// existing layers render exactly as before until the user customises
  /// them. [pathColor] is the layer's fog-veil ARGB; [pathOpacity] its
  /// veil opacity (0..1); [pathWidth] the corridor width (metres) applied
  /// to NEWLY recorded points on this layer.
  final int? pathColor;
  final double? pathOpacity;
  final double? pathWidth;

  /// Last local edit (rename, style, visibility). Sync merges rows by
  /// last-write-wins on this — null (pre-v8 rows, or never edited) loses to
  /// any non-null timestamp.
  final DateTime? updatedAt;
  const TrackLayer(
      {required this.id,
      required this.uuid,
      required this.name,
      required this.colorValue,
      required this.visible,
      this.tag,
      required this.createdAt,
      this.pathColor,
      this.pathOpacity,
      this.pathWidth,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['name'] = Variable<String>(name);
    map['color_value'] = Variable<int>(colorValue);
    map['visible'] = Variable<bool>(visible);
    if (!nullToAbsent || tag != null) {
      map['tag'] = Variable<String>(tag);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    if (!nullToAbsent || pathColor != null) {
      map['path_color'] = Variable<int>(pathColor);
    }
    if (!nullToAbsent || pathOpacity != null) {
      map['path_opacity'] = Variable<double>(pathOpacity);
    }
    if (!nullToAbsent || pathWidth != null) {
      map['path_width'] = Variable<double>(pathWidth);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  TrackLayersCompanion toCompanion(bool nullToAbsent) {
    return TrackLayersCompanion(
      id: Value(id),
      uuid: Value(uuid),
      name: Value(name),
      colorValue: Value(colorValue),
      visible: Value(visible),
      tag: tag == null && nullToAbsent ? const Value.absent() : Value(tag),
      createdAt: Value(createdAt),
      pathColor: pathColor == null && nullToAbsent
          ? const Value.absent()
          : Value(pathColor),
      pathOpacity: pathOpacity == null && nullToAbsent
          ? const Value.absent()
          : Value(pathOpacity),
      pathWidth: pathWidth == null && nullToAbsent
          ? const Value.absent()
          : Value(pathWidth),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory TrackLayer.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return TrackLayer(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      name: serializer.fromJson<String>(json['name']),
      colorValue: serializer.fromJson<int>(json['colorValue']),
      visible: serializer.fromJson<bool>(json['visible']),
      tag: serializer.fromJson<String?>(json['tag']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      pathColor: serializer.fromJson<int?>(json['pathColor']),
      pathOpacity: serializer.fromJson<double?>(json['pathOpacity']),
      pathWidth: serializer.fromJson<double?>(json['pathWidth']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'name': serializer.toJson<String>(name),
      'colorValue': serializer.toJson<int>(colorValue),
      'visible': serializer.toJson<bool>(visible),
      'tag': serializer.toJson<String?>(tag),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'pathColor': serializer.toJson<int?>(pathColor),
      'pathOpacity': serializer.toJson<double?>(pathOpacity),
      'pathWidth': serializer.toJson<double?>(pathWidth),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  TrackLayer copyWith(
          {int? id,
          String? uuid,
          String? name,
          int? colorValue,
          bool? visible,
          Value<String?> tag = const Value.absent(),
          DateTime? createdAt,
          Value<int?> pathColor = const Value.absent(),
          Value<double?> pathOpacity = const Value.absent(),
          Value<double?> pathWidth = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      TrackLayer(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        name: name ?? this.name,
        colorValue: colorValue ?? this.colorValue,
        visible: visible ?? this.visible,
        tag: tag.present ? tag.value : this.tag,
        createdAt: createdAt ?? this.createdAt,
        pathColor: pathColor.present ? pathColor.value : this.pathColor,
        pathOpacity: pathOpacity.present ? pathOpacity.value : this.pathOpacity,
        pathWidth: pathWidth.present ? pathWidth.value : this.pathWidth,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  TrackLayer copyWithCompanion(TrackLayersCompanion data) {
    return TrackLayer(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      name: data.name.present ? data.name.value : this.name,
      colorValue:
          data.colorValue.present ? data.colorValue.value : this.colorValue,
      visible: data.visible.present ? data.visible.value : this.visible,
      tag: data.tag.present ? data.tag.value : this.tag,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      pathColor: data.pathColor.present ? data.pathColor.value : this.pathColor,
      pathOpacity:
          data.pathOpacity.present ? data.pathOpacity.value : this.pathOpacity,
      pathWidth: data.pathWidth.present ? data.pathWidth.value : this.pathWidth,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('TrackLayer(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('visible: $visible, ')
          ..write('tag: $tag, ')
          ..write('createdAt: $createdAt, ')
          ..write('pathColor: $pathColor, ')
          ..write('pathOpacity: $pathOpacity, ')
          ..write('pathWidth: $pathWidth, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uuid, name, colorValue, visible, tag,
      createdAt, pathColor, pathOpacity, pathWidth, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is TrackLayer &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.name == this.name &&
          other.colorValue == this.colorValue &&
          other.visible == this.visible &&
          other.tag == this.tag &&
          other.createdAt == this.createdAt &&
          other.pathColor == this.pathColor &&
          other.pathOpacity == this.pathOpacity &&
          other.pathWidth == this.pathWidth &&
          other.updatedAt == this.updatedAt);
}

class TrackLayersCompanion extends UpdateCompanion<TrackLayer> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<String> name;
  final Value<int> colorValue;
  final Value<bool> visible;
  final Value<String?> tag;
  final Value<DateTime> createdAt;
  final Value<int?> pathColor;
  final Value<double?> pathOpacity;
  final Value<double?> pathWidth;
  final Value<DateTime?> updatedAt;
  const TrackLayersCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.name = const Value.absent(),
    this.colorValue = const Value.absent(),
    this.visible = const Value.absent(),
    this.tag = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.pathColor = const Value.absent(),
    this.pathOpacity = const Value.absent(),
    this.pathWidth = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  TrackLayersCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required String name,
    required int colorValue,
    this.visible = const Value.absent(),
    this.tag = const Value.absent(),
    required DateTime createdAt,
    this.pathColor = const Value.absent(),
    this.pathOpacity = const Value.absent(),
    this.pathWidth = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : name = Value(name),
        colorValue = Value(colorValue),
        createdAt = Value(createdAt);
  static Insertable<TrackLayer> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<String>? name,
    Expression<int>? colorValue,
    Expression<bool>? visible,
    Expression<String>? tag,
    Expression<DateTime>? createdAt,
    Expression<int>? pathColor,
    Expression<double>? pathOpacity,
    Expression<double>? pathWidth,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (name != null) 'name': name,
      if (colorValue != null) 'color_value': colorValue,
      if (visible != null) 'visible': visible,
      if (tag != null) 'tag': tag,
      if (createdAt != null) 'created_at': createdAt,
      if (pathColor != null) 'path_color': pathColor,
      if (pathOpacity != null) 'path_opacity': pathOpacity,
      if (pathWidth != null) 'path_width': pathWidth,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  TrackLayersCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<String>? name,
      Value<int>? colorValue,
      Value<bool>? visible,
      Value<String?>? tag,
      Value<DateTime>? createdAt,
      Value<int?>? pathColor,
      Value<double?>? pathOpacity,
      Value<double?>? pathWidth,
      Value<DateTime?>? updatedAt}) {
    return TrackLayersCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      name: name ?? this.name,
      colorValue: colorValue ?? this.colorValue,
      visible: visible ?? this.visible,
      tag: tag ?? this.tag,
      createdAt: createdAt ?? this.createdAt,
      pathColor: pathColor ?? this.pathColor,
      pathOpacity: pathOpacity ?? this.pathOpacity,
      pathWidth: pathWidth ?? this.pathWidth,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (colorValue.present) {
      map['color_value'] = Variable<int>(colorValue.value);
    }
    if (visible.present) {
      map['visible'] = Variable<bool>(visible.value);
    }
    if (tag.present) {
      map['tag'] = Variable<String>(tag.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (pathColor.present) {
      map['path_color'] = Variable<int>(pathColor.value);
    }
    if (pathOpacity.present) {
      map['path_opacity'] = Variable<double>(pathOpacity.value);
    }
    if (pathWidth.present) {
      map['path_width'] = Variable<double>(pathWidth.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TrackLayersCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('name: $name, ')
          ..write('colorValue: $colorValue, ')
          ..write('visible: $visible, ')
          ..write('tag: $tag, ')
          ..write('createdAt: $createdAt, ')
          ..write('pathColor: $pathColor, ')
          ..write('pathOpacity: $pathOpacity, ')
          ..write('pathWidth: $pathWidth, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $FogTilesTable extends FogTiles with TableInfo<$FogTilesTable, FogTile> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FogTilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tileXMeta = const VerificationMeta('tileX');
  @override
  late final GeneratedColumn<int> tileX = GeneratedColumn<int>(
      'tile_x', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tileYMeta = const VerificationMeta('tileY');
  @override
  late final GeneratedColumn<int> tileY = GeneratedColumn<int>(
      'tile_y', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _zoomMeta = const VerificationMeta('zoom');
  @override
  late final GeneratedColumn<int> zoom = GeneratedColumn<int>(
      'zoom', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _layerIdMeta =
      const VerificationMeta('layerId');
  @override
  late final GeneratedColumn<int> layerId = GeneratedColumn<int>(
      'layer_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _bitmapMeta = const VerificationMeta('bitmap');
  @override
  late final GeneratedColumn<Uint8List> bitmap = GeneratedColumn<Uint8List>(
      'bitmap', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [tileX, tileY, zoom, layerId, bitmap, updatedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'fog_tiles';
  @override
  VerificationContext validateIntegrity(Insertable<FogTile> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tile_x')) {
      context.handle(
          _tileXMeta, tileX.isAcceptableOrUnknown(data['tile_x']!, _tileXMeta));
    } else if (isInserting) {
      context.missing(_tileXMeta);
    }
    if (data.containsKey('tile_y')) {
      context.handle(
          _tileYMeta, tileY.isAcceptableOrUnknown(data['tile_y']!, _tileYMeta));
    } else if (isInserting) {
      context.missing(_tileYMeta);
    }
    if (data.containsKey('zoom')) {
      context.handle(
          _zoomMeta, zoom.isAcceptableOrUnknown(data['zoom']!, _zoomMeta));
    } else if (isInserting) {
      context.missing(_zoomMeta);
    }
    if (data.containsKey('layer_id')) {
      context.handle(_layerIdMeta,
          layerId.isAcceptableOrUnknown(data['layer_id']!, _layerIdMeta));
    } else if (isInserting) {
      context.missing(_layerIdMeta);
    }
    if (data.containsKey('bitmap')) {
      context.handle(_bitmapMeta,
          bitmap.isAcceptableOrUnknown(data['bitmap']!, _bitmapMeta));
    } else if (isInserting) {
      context.missing(_bitmapMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tileX, tileY, zoom, layerId};
  @override
  FogTile map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FogTile(
      tileX: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tile_x'])!,
      tileY: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tile_y'])!,
      zoom: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}zoom'])!,
      layerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}layer_id'])!,
      bitmap: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}bitmap'])!,
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
    );
  }

  @override
  $FogTilesTable createAlias(String alias) {
    return $FogTilesTable(attachedDatabase, alias);
  }
}

class FogTile extends DataClass implements Insertable<FogTile> {
  final int tileX;
  final int tileY;
  final int zoom;
  final int layerId;
  final Uint8List bitmap;
  final DateTime updatedAt;
  const FogTile(
      {required this.tileX,
      required this.tileY,
      required this.zoom,
      required this.layerId,
      required this.bitmap,
      required this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tile_x'] = Variable<int>(tileX);
    map['tile_y'] = Variable<int>(tileY);
    map['zoom'] = Variable<int>(zoom);
    map['layer_id'] = Variable<int>(layerId);
    map['bitmap'] = Variable<Uint8List>(bitmap);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  FogTilesCompanion toCompanion(bool nullToAbsent) {
    return FogTilesCompanion(
      tileX: Value(tileX),
      tileY: Value(tileY),
      zoom: Value(zoom),
      layerId: Value(layerId),
      bitmap: Value(bitmap),
      updatedAt: Value(updatedAt),
    );
  }

  factory FogTile.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FogTile(
      tileX: serializer.fromJson<int>(json['tileX']),
      tileY: serializer.fromJson<int>(json['tileY']),
      zoom: serializer.fromJson<int>(json['zoom']),
      layerId: serializer.fromJson<int>(json['layerId']),
      bitmap: serializer.fromJson<Uint8List>(json['bitmap']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tileX': serializer.toJson<int>(tileX),
      'tileY': serializer.toJson<int>(tileY),
      'zoom': serializer.toJson<int>(zoom),
      'layerId': serializer.toJson<int>(layerId),
      'bitmap': serializer.toJson<Uint8List>(bitmap),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  FogTile copyWith(
          {int? tileX,
          int? tileY,
          int? zoom,
          int? layerId,
          Uint8List? bitmap,
          DateTime? updatedAt}) =>
      FogTile(
        tileX: tileX ?? this.tileX,
        tileY: tileY ?? this.tileY,
        zoom: zoom ?? this.zoom,
        layerId: layerId ?? this.layerId,
        bitmap: bitmap ?? this.bitmap,
        updatedAt: updatedAt ?? this.updatedAt,
      );
  FogTile copyWithCompanion(FogTilesCompanion data) {
    return FogTile(
      tileX: data.tileX.present ? data.tileX.value : this.tileX,
      tileY: data.tileY.present ? data.tileY.value : this.tileY,
      zoom: data.zoom.present ? data.zoom.value : this.zoom,
      layerId: data.layerId.present ? data.layerId.value : this.layerId,
      bitmap: data.bitmap.present ? data.bitmap.value : this.bitmap,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FogTile(')
          ..write('tileX: $tileX, ')
          ..write('tileY: $tileY, ')
          ..write('zoom: $zoom, ')
          ..write('layerId: $layerId, ')
          ..write('bitmap: $bitmap, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      tileX, tileY, zoom, layerId, $driftBlobEquality.hash(bitmap), updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FogTile &&
          other.tileX == this.tileX &&
          other.tileY == this.tileY &&
          other.zoom == this.zoom &&
          other.layerId == this.layerId &&
          $driftBlobEquality.equals(other.bitmap, this.bitmap) &&
          other.updatedAt == this.updatedAt);
}

class FogTilesCompanion extends UpdateCompanion<FogTile> {
  final Value<int> tileX;
  final Value<int> tileY;
  final Value<int> zoom;
  final Value<int> layerId;
  final Value<Uint8List> bitmap;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const FogTilesCompanion({
    this.tileX = const Value.absent(),
    this.tileY = const Value.absent(),
    this.zoom = const Value.absent(),
    this.layerId = const Value.absent(),
    this.bitmap = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FogTilesCompanion.insert({
    required int tileX,
    required int tileY,
    required int zoom,
    required int layerId,
    required Uint8List bitmap,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  })  : tileX = Value(tileX),
        tileY = Value(tileY),
        zoom = Value(zoom),
        layerId = Value(layerId),
        bitmap = Value(bitmap),
        updatedAt = Value(updatedAt);
  static Insertable<FogTile> custom({
    Expression<int>? tileX,
    Expression<int>? tileY,
    Expression<int>? zoom,
    Expression<int>? layerId,
    Expression<Uint8List>? bitmap,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tileX != null) 'tile_x': tileX,
      if (tileY != null) 'tile_y': tileY,
      if (zoom != null) 'zoom': zoom,
      if (layerId != null) 'layer_id': layerId,
      if (bitmap != null) 'bitmap': bitmap,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FogTilesCompanion copyWith(
      {Value<int>? tileX,
      Value<int>? tileY,
      Value<int>? zoom,
      Value<int>? layerId,
      Value<Uint8List>? bitmap,
      Value<DateTime>? updatedAt,
      Value<int>? rowid}) {
    return FogTilesCompanion(
      tileX: tileX ?? this.tileX,
      tileY: tileY ?? this.tileY,
      zoom: zoom ?? this.zoom,
      layerId: layerId ?? this.layerId,
      bitmap: bitmap ?? this.bitmap,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tileX.present) {
      map['tile_x'] = Variable<int>(tileX.value);
    }
    if (tileY.present) {
      map['tile_y'] = Variable<int>(tileY.value);
    }
    if (zoom.present) {
      map['zoom'] = Variable<int>(zoom.value);
    }
    if (layerId.present) {
      map['layer_id'] = Variable<int>(layerId.value);
    }
    if (bitmap.present) {
      map['bitmap'] = Variable<Uint8List>(bitmap.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FogTilesCompanion(')
          ..write('tileX: $tileX, ')
          ..write('tileY: $tileY, ')
          ..write('zoom: $zoom, ')
          ..write('layerId: $layerId, ')
          ..write('bitmap: $bitmap, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $JournalEntriesTable extends JournalEntries
    with TableInfo<$JournalEntriesTable, JournalEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $JournalEntriesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<DateTime> time = GeneratedColumn<DateTime>(
      'time', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _lngMeta = const VerificationMeta('lng');
  @override
  late final GeneratedColumn<double> lng = GeneratedColumn<double>(
      'lng', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _richContentMeta =
      const VerificationMeta('richContent');
  @override
  late final GeneratedColumn<String> richContent = GeneratedColumn<String>(
      'rich_content', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _mediaPathsMeta =
      const VerificationMeta('mediaPaths');
  @override
  late final GeneratedColumn<String> mediaPaths = GeneratedColumn<String>(
      'media_paths', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _layerIdMeta =
      const VerificationMeta('layerId');
  @override
  late final GeneratedColumn<int> layerId = GeneratedColumn<int>(
      'layer_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _levelMeta = const VerificationMeta('level');
  @override
  late final GeneratedColumn<String> level = GeneratedColumn<String>(
      'level', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant('public'));
  static const VerificationMeta _ownerPeerIdMeta =
      const VerificationMeta('ownerPeerId');
  @override
  late final GeneratedColumn<String> ownerPeerId = GeneratedColumn<String>(
      'owner_peer_id', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _updatedAtMeta =
      const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
      'updated_at', aliasedName, true,
      type: DriftSqlType.dateTime, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns => [
        id,
        uuid,
        time,
        lat,
        lng,
        title,
        richContent,
        mediaPaths,
        layerId,
        level,
        ownerPeerId,
        updatedAt
      ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'journal_entries';
  @override
  VerificationContext validateIntegrity(Insertable<JournalEntry> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('time')) {
      context.handle(
          _timeMeta, time.isAcceptableOrUnknown(data['time']!, _timeMeta));
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    } else if (isInserting) {
      context.missing(_latMeta);
    }
    if (data.containsKey('lng')) {
      context.handle(
          _lngMeta, lng.isAcceptableOrUnknown(data['lng']!, _lngMeta));
    } else if (isInserting) {
      context.missing(_lngMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('rich_content')) {
      context.handle(
          _richContentMeta,
          richContent.isAcceptableOrUnknown(
              data['rich_content']!, _richContentMeta));
    }
    if (data.containsKey('media_paths')) {
      context.handle(
          _mediaPathsMeta,
          mediaPaths.isAcceptableOrUnknown(
              data['media_paths']!, _mediaPathsMeta));
    }
    if (data.containsKey('layer_id')) {
      context.handle(_layerIdMeta,
          layerId.isAcceptableOrUnknown(data['layer_id']!, _layerIdMeta));
    } else if (isInserting) {
      context.missing(_layerIdMeta);
    }
    if (data.containsKey('level')) {
      context.handle(
          _levelMeta, level.isAcceptableOrUnknown(data['level']!, _levelMeta));
    }
    if (data.containsKey('owner_peer_id')) {
      context.handle(
          _ownerPeerIdMeta,
          ownerPeerId.isAcceptableOrUnknown(
              data['owner_peer_id']!, _ownerPeerIdMeta));
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta,
          updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  JournalEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return JournalEntry(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      time: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}time'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat'])!,
      lng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lng'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      richContent: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}rich_content'])!,
      mediaPaths: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}media_paths'])!,
      layerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}layer_id'])!,
      level: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}level'])!,
      ownerPeerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}owner_peer_id']),
      updatedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at']),
    );
  }

  @override
  $JournalEntriesTable createAlias(String alias) {
    return $JournalEntriesTable(attachedDatabase, alias);
  }
}

class JournalEntry extends DataClass implements Insertable<JournalEntry> {
  final int id;
  final String uuid;
  final DateTime time;
  final double lat;
  final double lng;
  final String title;
  final String richContent;
  final String mediaPaths;
  final int layerId;

  /// 'public' (默认) | 'private' — drives whether the upload queue routes
  /// images to the public or private GitHub repo.
  final String level;

  /// Peer id of the traveler this entry belongs to, or null for "self".
  /// Free-form because peers in this app are P2P UUIDs, not joined records.
  final String? ownerPeerId;

  /// Last local edit. Sync merges entries by last-write-wins on this — null
  /// (pre-v8 rows, or never edited) loses to any non-null timestamp.
  final DateTime? updatedAt;
  const JournalEntry(
      {required this.id,
      required this.uuid,
      required this.time,
      required this.lat,
      required this.lng,
      required this.title,
      required this.richContent,
      required this.mediaPaths,
      required this.layerId,
      required this.level,
      this.ownerPeerId,
      this.updatedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['time'] = Variable<DateTime>(time);
    map['lat'] = Variable<double>(lat);
    map['lng'] = Variable<double>(lng);
    map['title'] = Variable<String>(title);
    map['rich_content'] = Variable<String>(richContent);
    map['media_paths'] = Variable<String>(mediaPaths);
    map['layer_id'] = Variable<int>(layerId);
    map['level'] = Variable<String>(level);
    if (!nullToAbsent || ownerPeerId != null) {
      map['owner_peer_id'] = Variable<String>(ownerPeerId);
    }
    if (!nullToAbsent || updatedAt != null) {
      map['updated_at'] = Variable<DateTime>(updatedAt);
    }
    return map;
  }

  JournalEntriesCompanion toCompanion(bool nullToAbsent) {
    return JournalEntriesCompanion(
      id: Value(id),
      uuid: Value(uuid),
      time: Value(time),
      lat: Value(lat),
      lng: Value(lng),
      title: Value(title),
      richContent: Value(richContent),
      mediaPaths: Value(mediaPaths),
      layerId: Value(layerId),
      level: Value(level),
      ownerPeerId: ownerPeerId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerPeerId),
      updatedAt: updatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(updatedAt),
    );
  }

  factory JournalEntry.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return JournalEntry(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      time: serializer.fromJson<DateTime>(json['time']),
      lat: serializer.fromJson<double>(json['lat']),
      lng: serializer.fromJson<double>(json['lng']),
      title: serializer.fromJson<String>(json['title']),
      richContent: serializer.fromJson<String>(json['richContent']),
      mediaPaths: serializer.fromJson<String>(json['mediaPaths']),
      layerId: serializer.fromJson<int>(json['layerId']),
      level: serializer.fromJson<String>(json['level']),
      ownerPeerId: serializer.fromJson<String?>(json['ownerPeerId']),
      updatedAt: serializer.fromJson<DateTime?>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'time': serializer.toJson<DateTime>(time),
      'lat': serializer.toJson<double>(lat),
      'lng': serializer.toJson<double>(lng),
      'title': serializer.toJson<String>(title),
      'richContent': serializer.toJson<String>(richContent),
      'mediaPaths': serializer.toJson<String>(mediaPaths),
      'layerId': serializer.toJson<int>(layerId),
      'level': serializer.toJson<String>(level),
      'ownerPeerId': serializer.toJson<String?>(ownerPeerId),
      'updatedAt': serializer.toJson<DateTime?>(updatedAt),
    };
  }

  JournalEntry copyWith(
          {int? id,
          String? uuid,
          DateTime? time,
          double? lat,
          double? lng,
          String? title,
          String? richContent,
          String? mediaPaths,
          int? layerId,
          String? level,
          Value<String?> ownerPeerId = const Value.absent(),
          Value<DateTime?> updatedAt = const Value.absent()}) =>
      JournalEntry(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        time: time ?? this.time,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        title: title ?? this.title,
        richContent: richContent ?? this.richContent,
        mediaPaths: mediaPaths ?? this.mediaPaths,
        layerId: layerId ?? this.layerId,
        level: level ?? this.level,
        ownerPeerId: ownerPeerId.present ? ownerPeerId.value : this.ownerPeerId,
        updatedAt: updatedAt.present ? updatedAt.value : this.updatedAt,
      );
  JournalEntry copyWithCompanion(JournalEntriesCompanion data) {
    return JournalEntry(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      time: data.time.present ? data.time.value : this.time,
      lat: data.lat.present ? data.lat.value : this.lat,
      lng: data.lng.present ? data.lng.value : this.lng,
      title: data.title.present ? data.title.value : this.title,
      richContent:
          data.richContent.present ? data.richContent.value : this.richContent,
      mediaPaths:
          data.mediaPaths.present ? data.mediaPaths.value : this.mediaPaths,
      layerId: data.layerId.present ? data.layerId.value : this.layerId,
      level: data.level.present ? data.level.value : this.level,
      ownerPeerId:
          data.ownerPeerId.present ? data.ownerPeerId.value : this.ownerPeerId,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('JournalEntry(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('time: $time, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('title: $title, ')
          ..write('richContent: $richContent, ')
          ..write('mediaPaths: $mediaPaths, ')
          ..write('layerId: $layerId, ')
          ..write('level: $level, ')
          ..write('ownerPeerId: $ownerPeerId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, uuid, time, lat, lng, title, richContent,
      mediaPaths, layerId, level, ownerPeerId, updatedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is JournalEntry &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.time == this.time &&
          other.lat == this.lat &&
          other.lng == this.lng &&
          other.title == this.title &&
          other.richContent == this.richContent &&
          other.mediaPaths == this.mediaPaths &&
          other.layerId == this.layerId &&
          other.level == this.level &&
          other.ownerPeerId == this.ownerPeerId &&
          other.updatedAt == this.updatedAt);
}

class JournalEntriesCompanion extends UpdateCompanion<JournalEntry> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<DateTime> time;
  final Value<double> lat;
  final Value<double> lng;
  final Value<String> title;
  final Value<String> richContent;
  final Value<String> mediaPaths;
  final Value<int> layerId;
  final Value<String> level;
  final Value<String?> ownerPeerId;
  final Value<DateTime?> updatedAt;
  const JournalEntriesCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.time = const Value.absent(),
    this.lat = const Value.absent(),
    this.lng = const Value.absent(),
    this.title = const Value.absent(),
    this.richContent = const Value.absent(),
    this.mediaPaths = const Value.absent(),
    this.layerId = const Value.absent(),
    this.level = const Value.absent(),
    this.ownerPeerId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  JournalEntriesCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required DateTime time,
    required double lat,
    required double lng,
    required String title,
    this.richContent = const Value.absent(),
    this.mediaPaths = const Value.absent(),
    required int layerId,
    this.level = const Value.absent(),
    this.ownerPeerId = const Value.absent(),
    this.updatedAt = const Value.absent(),
  })  : time = Value(time),
        lat = Value(lat),
        lng = Value(lng),
        title = Value(title),
        layerId = Value(layerId);
  static Insertable<JournalEntry> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<DateTime>? time,
    Expression<double>? lat,
    Expression<double>? lng,
    Expression<String>? title,
    Expression<String>? richContent,
    Expression<String>? mediaPaths,
    Expression<int>? layerId,
    Expression<String>? level,
    Expression<String>? ownerPeerId,
    Expression<DateTime>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (time != null) 'time': time,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (title != null) 'title': title,
      if (richContent != null) 'rich_content': richContent,
      if (mediaPaths != null) 'media_paths': mediaPaths,
      if (layerId != null) 'layer_id': layerId,
      if (level != null) 'level': level,
      if (ownerPeerId != null) 'owner_peer_id': ownerPeerId,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  JournalEntriesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<DateTime>? time,
      Value<double>? lat,
      Value<double>? lng,
      Value<String>? title,
      Value<String>? richContent,
      Value<String>? mediaPaths,
      Value<int>? layerId,
      Value<String>? level,
      Value<String?>? ownerPeerId,
      Value<DateTime?>? updatedAt}) {
    return JournalEntriesCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      time: time ?? this.time,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      title: title ?? this.title,
      richContent: richContent ?? this.richContent,
      mediaPaths: mediaPaths ?? this.mediaPaths,
      layerId: layerId ?? this.layerId,
      level: level ?? this.level,
      ownerPeerId: ownerPeerId ?? this.ownerPeerId,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (time.present) {
      map['time'] = Variable<DateTime>(time.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lng.present) {
      map['lng'] = Variable<double>(lng.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (richContent.present) {
      map['rich_content'] = Variable<String>(richContent.value);
    }
    if (mediaPaths.present) {
      map['media_paths'] = Variable<String>(mediaPaths.value);
    }
    if (layerId.present) {
      map['layer_id'] = Variable<int>(layerId.value);
    }
    if (level.present) {
      map['level'] = Variable<String>(level.value);
    }
    if (ownerPeerId.present) {
      map['owner_peer_id'] = Variable<String>(ownerPeerId.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('JournalEntriesCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('time: $time, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('title: $title, ')
          ..write('richContent: $richContent, ')
          ..write('mediaPaths: $mediaPaths, ')
          ..write('layerId: $layerId, ')
          ..write('level: $level, ')
          ..write('ownerPeerId: $ownerPeerId, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $ChatMessagesTable extends ChatMessages
    with TableInfo<$ChatMessagesTable, ChatMessage> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ChatMessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _authorMeta = const VerificationMeta('author');
  @override
  late final GeneratedColumn<String> author = GeneratedColumn<String>(
      'author', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _contentMeta =
      const VerificationMeta('content');
  @override
  late final GeneratedColumn<String> content = GeneratedColumn<String>(
      'content', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<DateTime> time = GeneratedColumn<DateTime>(
      'time', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _outboundMeta =
      const VerificationMeta('outbound');
  @override
  late final GeneratedColumn<bool> outbound = GeneratedColumn<bool>(
      'outbound', aliasedName, false,
      type: DriftSqlType.bool,
      requiredDuringInsert: true,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('CHECK ("outbound" IN (0, 1))'));
  @override
  List<GeneratedColumn> get $columns =>
      [id, uuid, peerId, author, content, time, outbound];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'chat_messages';
  @override
  VerificationContext validateIntegrity(Insertable<ChatMessage> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('author')) {
      context.handle(_authorMeta,
          author.isAcceptableOrUnknown(data['author']!, _authorMeta));
    } else if (isInserting) {
      context.missing(_authorMeta);
    }
    if (data.containsKey('content')) {
      context.handle(_contentMeta,
          content.isAcceptableOrUnknown(data['content']!, _contentMeta));
    } else if (isInserting) {
      context.missing(_contentMeta);
    }
    if (data.containsKey('time')) {
      context.handle(
          _timeMeta, time.isAcceptableOrUnknown(data['time']!, _timeMeta));
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    if (data.containsKey('outbound')) {
      context.handle(_outboundMeta,
          outbound.isAcceptableOrUnknown(data['outbound']!, _outboundMeta));
    } else if (isInserting) {
      context.missing(_outboundMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ChatMessage map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ChatMessage(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      author: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}author'])!,
      content: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}content'])!,
      time: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}time'])!,
      outbound: attachedDatabase.typeMapping
          .read(DriftSqlType.bool, data['${effectivePrefix}outbound'])!,
    );
  }

  @override
  $ChatMessagesTable createAlias(String alias) {
    return $ChatMessagesTable(attachedDatabase, alias);
  }
}

class ChatMessage extends DataClass implements Insertable<ChatMessage> {
  final int id;
  final String uuid;
  final String peerId;
  final String author;
  final String content;
  final DateTime time;
  final bool outbound;
  const ChatMessage(
      {required this.id,
      required this.uuid,
      required this.peerId,
      required this.author,
      required this.content,
      required this.time,
      required this.outbound});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['peer_id'] = Variable<String>(peerId);
    map['author'] = Variable<String>(author);
    map['content'] = Variable<String>(content);
    map['time'] = Variable<DateTime>(time);
    map['outbound'] = Variable<bool>(outbound);
    return map;
  }

  ChatMessagesCompanion toCompanion(bool nullToAbsent) {
    return ChatMessagesCompanion(
      id: Value(id),
      uuid: Value(uuid),
      peerId: Value(peerId),
      author: Value(author),
      content: Value(content),
      time: Value(time),
      outbound: Value(outbound),
    );
  }

  factory ChatMessage.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ChatMessage(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      peerId: serializer.fromJson<String>(json['peerId']),
      author: serializer.fromJson<String>(json['author']),
      content: serializer.fromJson<String>(json['content']),
      time: serializer.fromJson<DateTime>(json['time']),
      outbound: serializer.fromJson<bool>(json['outbound']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'peerId': serializer.toJson<String>(peerId),
      'author': serializer.toJson<String>(author),
      'content': serializer.toJson<String>(content),
      'time': serializer.toJson<DateTime>(time),
      'outbound': serializer.toJson<bool>(outbound),
    };
  }

  ChatMessage copyWith(
          {int? id,
          String? uuid,
          String? peerId,
          String? author,
          String? content,
          DateTime? time,
          bool? outbound}) =>
      ChatMessage(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        peerId: peerId ?? this.peerId,
        author: author ?? this.author,
        content: content ?? this.content,
        time: time ?? this.time,
        outbound: outbound ?? this.outbound,
      );
  ChatMessage copyWithCompanion(ChatMessagesCompanion data) {
    return ChatMessage(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      author: data.author.present ? data.author.value : this.author,
      content: data.content.present ? data.content.value : this.content,
      time: data.time.present ? data.time.value : this.time,
      outbound: data.outbound.present ? data.outbound.value : this.outbound,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessage(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('peerId: $peerId, ')
          ..write('author: $author, ')
          ..write('content: $content, ')
          ..write('time: $time, ')
          ..write('outbound: $outbound')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, uuid, peerId, author, content, time, outbound);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ChatMessage &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.peerId == this.peerId &&
          other.author == this.author &&
          other.content == this.content &&
          other.time == this.time &&
          other.outbound == this.outbound);
}

class ChatMessagesCompanion extends UpdateCompanion<ChatMessage> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<String> peerId;
  final Value<String> author;
  final Value<String> content;
  final Value<DateTime> time;
  final Value<bool> outbound;
  const ChatMessagesCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.peerId = const Value.absent(),
    this.author = const Value.absent(),
    this.content = const Value.absent(),
    this.time = const Value.absent(),
    this.outbound = const Value.absent(),
  });
  ChatMessagesCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required String peerId,
    required String author,
    required String content,
    required DateTime time,
    required bool outbound,
  })  : peerId = Value(peerId),
        author = Value(author),
        content = Value(content),
        time = Value(time),
        outbound = Value(outbound);
  static Insertable<ChatMessage> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<String>? peerId,
    Expression<String>? author,
    Expression<String>? content,
    Expression<DateTime>? time,
    Expression<bool>? outbound,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (peerId != null) 'peer_id': peerId,
      if (author != null) 'author': author,
      if (content != null) 'content': content,
      if (time != null) 'time': time,
      if (outbound != null) 'outbound': outbound,
    });
  }

  ChatMessagesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<String>? peerId,
      Value<String>? author,
      Value<String>? content,
      Value<DateTime>? time,
      Value<bool>? outbound}) {
    return ChatMessagesCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      peerId: peerId ?? this.peerId,
      author: author ?? this.author,
      content: content ?? this.content,
      time: time ?? this.time,
      outbound: outbound ?? this.outbound,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (author.present) {
      map['author'] = Variable<String>(author.value);
    }
    if (content.present) {
      map['content'] = Variable<String>(content.value);
    }
    if (time.present) {
      map['time'] = Variable<DateTime>(time.value);
    }
    if (outbound.present) {
      map['outbound'] = Variable<bool>(outbound.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ChatMessagesCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('peerId: $peerId, ')
          ..write('author: $author, ')
          ..write('content: $content, ')
          ..write('time: $time, ')
          ..write('outbound: $outbound')
          ..write(')'))
        .toString();
  }
}

class $SongFavoritesTable extends SongFavorites
    with TableInfo<$SongFavoritesTable, SongFavorite> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SongFavoritesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _songIdMeta = const VerificationMeta('songId');
  @override
  late final GeneratedColumn<String> songId = GeneratedColumn<String>(
      'song_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
      'title', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
      'artist', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _coverUrlMeta =
      const VerificationMeta('coverUrl');
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
      'cover_url', aliasedName, true,
      type: DriftSqlType.string, requiredDuringInsert: false);
  static const VerificationMeta _sourceMeta = const VerificationMeta('source');
  @override
  late final GeneratedColumn<String> source = GeneratedColumn<String>(
      'source', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _addedAtMeta =
      const VerificationMeta('addedAt');
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
      'added_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  static const VerificationMeta _lngMeta = const VerificationMeta('lng');
  @override
  late final GeneratedColumn<double> lng = GeneratedColumn<double>(
      'lng', aliasedName, true,
      type: DriftSqlType.double, requiredDuringInsert: false);
  @override
  List<GeneratedColumn> get $columns =>
      [id, uuid, songId, title, artist, coverUrl, source, addedAt, lat, lng];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'song_favorites';
  @override
  VerificationContext validateIntegrity(Insertable<SongFavorite> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    }
    if (data.containsKey('song_id')) {
      context.handle(_songIdMeta,
          songId.isAcceptableOrUnknown(data['song_id']!, _songIdMeta));
    } else if (isInserting) {
      context.missing(_songIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
          _titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(_artistMeta,
          artist.isAcceptableOrUnknown(data['artist']!, _artistMeta));
    } else if (isInserting) {
      context.missing(_artistMeta);
    }
    if (data.containsKey('cover_url')) {
      context.handle(_coverUrlMeta,
          coverUrl.isAcceptableOrUnknown(data['cover_url']!, _coverUrlMeta));
    }
    if (data.containsKey('source')) {
      context.handle(_sourceMeta,
          source.isAcceptableOrUnknown(data['source']!, _sourceMeta));
    } else if (isInserting) {
      context.missing(_sourceMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(_addedAtMeta,
          addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta));
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    }
    if (data.containsKey('lng')) {
      context.handle(
          _lngMeta, lng.isAcceptableOrUnknown(data['lng']!, _lngMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SongFavorite map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SongFavorite(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      songId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}song_id'])!,
      title: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      artist: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}artist'])!,
      coverUrl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}cover_url']),
      source: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}source'])!,
      addedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}added_at'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat']),
      lng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lng']),
    );
  }

  @override
  $SongFavoritesTable createAlias(String alias) {
    return $SongFavoritesTable(attachedDatabase, alias);
  }
}

class SongFavorite extends DataClass implements Insertable<SongFavorite> {
  final int id;
  final String uuid;
  final String songId;
  final String title;
  final String artist;
  final String? coverUrl;
  final String source;
  final DateTime addedAt;
  final double? lat;
  final double? lng;
  const SongFavorite(
      {required this.id,
      required this.uuid,
      required this.songId,
      required this.title,
      required this.artist,
      this.coverUrl,
      required this.source,
      required this.addedAt,
      this.lat,
      this.lng});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['uuid'] = Variable<String>(uuid);
    map['song_id'] = Variable<String>(songId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    if (!nullToAbsent || coverUrl != null) {
      map['cover_url'] = Variable<String>(coverUrl);
    }
    map['source'] = Variable<String>(source);
    map['added_at'] = Variable<DateTime>(addedAt);
    if (!nullToAbsent || lat != null) {
      map['lat'] = Variable<double>(lat);
    }
    if (!nullToAbsent || lng != null) {
      map['lng'] = Variable<double>(lng);
    }
    return map;
  }

  SongFavoritesCompanion toCompanion(bool nullToAbsent) {
    return SongFavoritesCompanion(
      id: Value(id),
      uuid: Value(uuid),
      songId: Value(songId),
      title: Value(title),
      artist: Value(artist),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      source: Value(source),
      addedAt: Value(addedAt),
      lat: lat == null && nullToAbsent ? const Value.absent() : Value(lat),
      lng: lng == null && nullToAbsent ? const Value.absent() : Value(lng),
    );
  }

  factory SongFavorite.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SongFavorite(
      id: serializer.fromJson<int>(json['id']),
      uuid: serializer.fromJson<String>(json['uuid']),
      songId: serializer.fromJson<String>(json['songId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      source: serializer.fromJson<String>(json['source']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
      lat: serializer.fromJson<double?>(json['lat']),
      lng: serializer.fromJson<double?>(json['lng']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'uuid': serializer.toJson<String>(uuid),
      'songId': serializer.toJson<String>(songId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'source': serializer.toJson<String>(source),
      'addedAt': serializer.toJson<DateTime>(addedAt),
      'lat': serializer.toJson<double?>(lat),
      'lng': serializer.toJson<double?>(lng),
    };
  }

  SongFavorite copyWith(
          {int? id,
          String? uuid,
          String? songId,
          String? title,
          String? artist,
          Value<String?> coverUrl = const Value.absent(),
          String? source,
          DateTime? addedAt,
          Value<double?> lat = const Value.absent(),
          Value<double?> lng = const Value.absent()}) =>
      SongFavorite(
        id: id ?? this.id,
        uuid: uuid ?? this.uuid,
        songId: songId ?? this.songId,
        title: title ?? this.title,
        artist: artist ?? this.artist,
        coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
        source: source ?? this.source,
        addedAt: addedAt ?? this.addedAt,
        lat: lat.present ? lat.value : this.lat,
        lng: lng.present ? lng.value : this.lng,
      );
  SongFavorite copyWithCompanion(SongFavoritesCompanion data) {
    return SongFavorite(
      id: data.id.present ? data.id.value : this.id,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      songId: data.songId.present ? data.songId.value : this.songId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      source: data.source.present ? data.source.value : this.source,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      lat: data.lat.present ? data.lat.value : this.lat,
      lng: data.lng.present ? data.lng.value : this.lng,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SongFavorite(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('source: $source, ')
          ..write('addedAt: $addedAt, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      id, uuid, songId, title, artist, coverUrl, source, addedAt, lat, lng);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SongFavorite &&
          other.id == this.id &&
          other.uuid == this.uuid &&
          other.songId == this.songId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.coverUrl == this.coverUrl &&
          other.source == this.source &&
          other.addedAt == this.addedAt &&
          other.lat == this.lat &&
          other.lng == this.lng);
}

class SongFavoritesCompanion extends UpdateCompanion<SongFavorite> {
  final Value<int> id;
  final Value<String> uuid;
  final Value<String> songId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String?> coverUrl;
  final Value<String> source;
  final Value<DateTime> addedAt;
  final Value<double?> lat;
  final Value<double?> lng;
  const SongFavoritesCompanion({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    this.songId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.source = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.lat = const Value.absent(),
    this.lng = const Value.absent(),
  });
  SongFavoritesCompanion.insert({
    this.id = const Value.absent(),
    this.uuid = const Value.absent(),
    required String songId,
    required String title,
    required String artist,
    this.coverUrl = const Value.absent(),
    required String source,
    required DateTime addedAt,
    this.lat = const Value.absent(),
    this.lng = const Value.absent(),
  })  : songId = Value(songId),
        title = Value(title),
        artist = Value(artist),
        source = Value(source),
        addedAt = Value(addedAt);
  static Insertable<SongFavorite> custom({
    Expression<int>? id,
    Expression<String>? uuid,
    Expression<String>? songId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? coverUrl,
    Expression<String>? source,
    Expression<DateTime>? addedAt,
    Expression<double>? lat,
    Expression<double>? lng,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (uuid != null) 'uuid': uuid,
      if (songId != null) 'song_id': songId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (coverUrl != null) 'cover_url': coverUrl,
      if (source != null) 'source': source,
      if (addedAt != null) 'added_at': addedAt,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
    });
  }

  SongFavoritesCompanion copyWith(
      {Value<int>? id,
      Value<String>? uuid,
      Value<String>? songId,
      Value<String>? title,
      Value<String>? artist,
      Value<String?>? coverUrl,
      Value<String>? source,
      Value<DateTime>? addedAt,
      Value<double?>? lat,
      Value<double?>? lng}) {
    return SongFavoritesCompanion(
      id: id ?? this.id,
      uuid: uuid ?? this.uuid,
      songId: songId ?? this.songId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      coverUrl: coverUrl ?? this.coverUrl,
      source: source ?? this.source,
      addedAt: addedAt ?? this.addedAt,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (songId.present) {
      map['song_id'] = Variable<String>(songId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (coverUrl.present) {
      map['cover_url'] = Variable<String>(coverUrl.value);
    }
    if (source.present) {
      map['source'] = Variable<String>(source.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lng.present) {
      map['lng'] = Variable<double>(lng.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SongFavoritesCompanion(')
          ..write('id: $id, ')
          ..write('uuid: $uuid, ')
          ..write('songId: $songId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('source: $source, ')
          ..write('addedAt: $addedAt, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng')
          ..write(')'))
        .toString();
  }
}

class $PeerLocationsTable extends PeerLocations
    with TableInfo<$PeerLocationsTable, PeerLocation> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PeerLocationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
      'id', aliasedName, false,
      hasAutoIncrement: true,
      type: DriftSqlType.int,
      requiredDuringInsert: false,
      defaultConstraints:
          GeneratedColumn.constraintIsAlways('PRIMARY KEY AUTOINCREMENT'));
  static const VerificationMeta _peerIdMeta = const VerificationMeta('peerId');
  @override
  late final GeneratedColumn<String> peerId = GeneratedColumn<String>(
      'peer_id', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _peerNameMeta =
      const VerificationMeta('peerName');
  @override
  late final GeneratedColumn<String> peerName = GeneratedColumn<String>(
      'peer_name', aliasedName, false,
      type: DriftSqlType.string,
      requiredDuringInsert: false,
      defaultValue: const Constant(''));
  static const VerificationMeta _latMeta = const VerificationMeta('lat');
  @override
  late final GeneratedColumn<double> lat = GeneratedColumn<double>(
      'lat', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _lngMeta = const VerificationMeta('lng');
  @override
  late final GeneratedColumn<double> lng = GeneratedColumn<double>(
      'lng', aliasedName, false,
      type: DriftSqlType.double, requiredDuringInsert: true);
  static const VerificationMeta _timeMeta = const VerificationMeta('time');
  @override
  late final GeneratedColumn<DateTime> time = GeneratedColumn<DateTime>(
      'time', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [id, peerId, peerName, lat, lng, time];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'peer_locations';
  @override
  VerificationContext validateIntegrity(Insertable<PeerLocation> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('peer_id')) {
      context.handle(_peerIdMeta,
          peerId.isAcceptableOrUnknown(data['peer_id']!, _peerIdMeta));
    } else if (isInserting) {
      context.missing(_peerIdMeta);
    }
    if (data.containsKey('peer_name')) {
      context.handle(_peerNameMeta,
          peerName.isAcceptableOrUnknown(data['peer_name']!, _peerNameMeta));
    }
    if (data.containsKey('lat')) {
      context.handle(
          _latMeta, lat.isAcceptableOrUnknown(data['lat']!, _latMeta));
    } else if (isInserting) {
      context.missing(_latMeta);
    }
    if (data.containsKey('lng')) {
      context.handle(
          _lngMeta, lng.isAcceptableOrUnknown(data['lng']!, _lngMeta));
    } else if (isInserting) {
      context.missing(_lngMeta);
    }
    if (data.containsKey('time')) {
      context.handle(
          _timeMeta, time.isAcceptableOrUnknown(data['time']!, _timeMeta));
    } else if (isInserting) {
      context.missing(_timeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PeerLocation map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PeerLocation(
      id: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}id'])!,
      peerId: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_id'])!,
      peerName: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}peer_name'])!,
      lat: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lat'])!,
      lng: attachedDatabase.typeMapping
          .read(DriftSqlType.double, data['${effectivePrefix}lng'])!,
      time: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}time'])!,
    );
  }

  @override
  $PeerLocationsTable createAlias(String alias) {
    return $PeerLocationsTable(attachedDatabase, alias);
  }
}

class PeerLocation extends DataClass implements Insertable<PeerLocation> {
  final int id;
  final String peerId;
  final String peerName;
  final double lat;
  final double lng;
  final DateTime time;
  const PeerLocation(
      {required this.id,
      required this.peerId,
      required this.peerName,
      required this.lat,
      required this.lng,
      required this.time});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['peer_id'] = Variable<String>(peerId);
    map['peer_name'] = Variable<String>(peerName);
    map['lat'] = Variable<double>(lat);
    map['lng'] = Variable<double>(lng);
    map['time'] = Variable<DateTime>(time);
    return map;
  }

  PeerLocationsCompanion toCompanion(bool nullToAbsent) {
    return PeerLocationsCompanion(
      id: Value(id),
      peerId: Value(peerId),
      peerName: Value(peerName),
      lat: Value(lat),
      lng: Value(lng),
      time: Value(time),
    );
  }

  factory PeerLocation.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PeerLocation(
      id: serializer.fromJson<int>(json['id']),
      peerId: serializer.fromJson<String>(json['peerId']),
      peerName: serializer.fromJson<String>(json['peerName']),
      lat: serializer.fromJson<double>(json['lat']),
      lng: serializer.fromJson<double>(json['lng']),
      time: serializer.fromJson<DateTime>(json['time']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'peerId': serializer.toJson<String>(peerId),
      'peerName': serializer.toJson<String>(peerName),
      'lat': serializer.toJson<double>(lat),
      'lng': serializer.toJson<double>(lng),
      'time': serializer.toJson<DateTime>(time),
    };
  }

  PeerLocation copyWith(
          {int? id,
          String? peerId,
          String? peerName,
          double? lat,
          double? lng,
          DateTime? time}) =>
      PeerLocation(
        id: id ?? this.id,
        peerId: peerId ?? this.peerId,
        peerName: peerName ?? this.peerName,
        lat: lat ?? this.lat,
        lng: lng ?? this.lng,
        time: time ?? this.time,
      );
  PeerLocation copyWithCompanion(PeerLocationsCompanion data) {
    return PeerLocation(
      id: data.id.present ? data.id.value : this.id,
      peerId: data.peerId.present ? data.peerId.value : this.peerId,
      peerName: data.peerName.present ? data.peerName.value : this.peerName,
      lat: data.lat.present ? data.lat.value : this.lat,
      lng: data.lng.present ? data.lng.value : this.lng,
      time: data.time.present ? data.time.value : this.time,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PeerLocation(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('peerName: $peerName, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('time: $time')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, peerId, peerName, lat, lng, time);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PeerLocation &&
          other.id == this.id &&
          other.peerId == this.peerId &&
          other.peerName == this.peerName &&
          other.lat == this.lat &&
          other.lng == this.lng &&
          other.time == this.time);
}

class PeerLocationsCompanion extends UpdateCompanion<PeerLocation> {
  final Value<int> id;
  final Value<String> peerId;
  final Value<String> peerName;
  final Value<double> lat;
  final Value<double> lng;
  final Value<DateTime> time;
  const PeerLocationsCompanion({
    this.id = const Value.absent(),
    this.peerId = const Value.absent(),
    this.peerName = const Value.absent(),
    this.lat = const Value.absent(),
    this.lng = const Value.absent(),
    this.time = const Value.absent(),
  });
  PeerLocationsCompanion.insert({
    this.id = const Value.absent(),
    required String peerId,
    this.peerName = const Value.absent(),
    required double lat,
    required double lng,
    required DateTime time,
  })  : peerId = Value(peerId),
        lat = Value(lat),
        lng = Value(lng),
        time = Value(time);
  static Insertable<PeerLocation> custom({
    Expression<int>? id,
    Expression<String>? peerId,
    Expression<String>? peerName,
    Expression<double>? lat,
    Expression<double>? lng,
    Expression<DateTime>? time,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (peerId != null) 'peer_id': peerId,
      if (peerName != null) 'peer_name': peerName,
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (time != null) 'time': time,
    });
  }

  PeerLocationsCompanion copyWith(
      {Value<int>? id,
      Value<String>? peerId,
      Value<String>? peerName,
      Value<double>? lat,
      Value<double>? lng,
      Value<DateTime>? time}) {
    return PeerLocationsCompanion(
      id: id ?? this.id,
      peerId: peerId ?? this.peerId,
      peerName: peerName ?? this.peerName,
      lat: lat ?? this.lat,
      lng: lng ?? this.lng,
      time: time ?? this.time,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (peerId.present) {
      map['peer_id'] = Variable<String>(peerId.value);
    }
    if (peerName.present) {
      map['peer_name'] = Variable<String>(peerName.value);
    }
    if (lat.present) {
      map['lat'] = Variable<double>(lat.value);
    }
    if (lng.present) {
      map['lng'] = Variable<double>(lng.value);
    }
    if (time.present) {
      map['time'] = Variable<DateTime>(time.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PeerLocationsCompanion(')
          ..write('id: $id, ')
          ..write('peerId: $peerId, ')
          ..write('peerName: $peerName, ')
          ..write('lat: $lat, ')
          ..write('lng: $lng, ')
          ..write('time: $time')
          ..write(')'))
        .toString();
  }
}

class $TombstonesTable extends Tombstones
    with TableInfo<$TombstonesTable, Tombstone> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $TombstonesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tblMeta = const VerificationMeta('tbl');
  @override
  late final GeneratedColumn<String> tbl = GeneratedColumn<String>(
      'tbl', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _uuidMeta = const VerificationMeta('uuid');
  @override
  late final GeneratedColumn<String> uuid = GeneratedColumn<String>(
      'uuid', aliasedName, false,
      type: DriftSqlType.string, requiredDuringInsert: true);
  static const VerificationMeta _deletedAtMeta =
      const VerificationMeta('deletedAt');
  @override
  late final GeneratedColumn<DateTime> deletedAt = GeneratedColumn<DateTime>(
      'deleted_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns => [tbl, uuid, deletedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'tombstones';
  @override
  VerificationContext validateIntegrity(Insertable<Tombstone> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tbl')) {
      context.handle(
          _tblMeta, tbl.isAcceptableOrUnknown(data['tbl']!, _tblMeta));
    } else if (isInserting) {
      context.missing(_tblMeta);
    }
    if (data.containsKey('uuid')) {
      context.handle(
          _uuidMeta, uuid.isAcceptableOrUnknown(data['uuid']!, _uuidMeta));
    } else if (isInserting) {
      context.missing(_uuidMeta);
    }
    if (data.containsKey('deleted_at')) {
      context.handle(_deletedAtMeta,
          deletedAt.isAcceptableOrUnknown(data['deleted_at']!, _deletedAtMeta));
    } else if (isInserting) {
      context.missing(_deletedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tbl, uuid};
  @override
  Tombstone map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return Tombstone(
      tbl: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}tbl'])!,
      uuid: attachedDatabase.typeMapping
          .read(DriftSqlType.string, data['${effectivePrefix}uuid'])!,
      deletedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}deleted_at'])!,
    );
  }

  @override
  $TombstonesTable createAlias(String alias) {
    return $TombstonesTable(attachedDatabase, alias);
  }
}

class Tombstone extends DataClass implements Insertable<Tombstone> {
  /// Logical (SQL) table name, e.g. 'track_points', 'journal_entries'.
  final String tbl;
  final String uuid;
  final DateTime deletedAt;
  const Tombstone(
      {required this.tbl, required this.uuid, required this.deletedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tbl'] = Variable<String>(tbl);
    map['uuid'] = Variable<String>(uuid);
    map['deleted_at'] = Variable<DateTime>(deletedAt);
    return map;
  }

  TombstonesCompanion toCompanion(bool nullToAbsent) {
    return TombstonesCompanion(
      tbl: Value(tbl),
      uuid: Value(uuid),
      deletedAt: Value(deletedAt),
    );
  }

  factory Tombstone.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return Tombstone(
      tbl: serializer.fromJson<String>(json['tbl']),
      uuid: serializer.fromJson<String>(json['uuid']),
      deletedAt: serializer.fromJson<DateTime>(json['deletedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tbl': serializer.toJson<String>(tbl),
      'uuid': serializer.toJson<String>(uuid),
      'deletedAt': serializer.toJson<DateTime>(deletedAt),
    };
  }

  Tombstone copyWith({String? tbl, String? uuid, DateTime? deletedAt}) =>
      Tombstone(
        tbl: tbl ?? this.tbl,
        uuid: uuid ?? this.uuid,
        deletedAt: deletedAt ?? this.deletedAt,
      );
  Tombstone copyWithCompanion(TombstonesCompanion data) {
    return Tombstone(
      tbl: data.tbl.present ? data.tbl.value : this.tbl,
      uuid: data.uuid.present ? data.uuid.value : this.uuid,
      deletedAt: data.deletedAt.present ? data.deletedAt.value : this.deletedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('Tombstone(')
          ..write('tbl: $tbl, ')
          ..write('uuid: $uuid, ')
          ..write('deletedAt: $deletedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(tbl, uuid, deletedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is Tombstone &&
          other.tbl == this.tbl &&
          other.uuid == this.uuid &&
          other.deletedAt == this.deletedAt);
}

class TombstonesCompanion extends UpdateCompanion<Tombstone> {
  final Value<String> tbl;
  final Value<String> uuid;
  final Value<DateTime> deletedAt;
  final Value<int> rowid;
  const TombstonesCompanion({
    this.tbl = const Value.absent(),
    this.uuid = const Value.absent(),
    this.deletedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  TombstonesCompanion.insert({
    required String tbl,
    required String uuid,
    required DateTime deletedAt,
    this.rowid = const Value.absent(),
  })  : tbl = Value(tbl),
        uuid = Value(uuid),
        deletedAt = Value(deletedAt);
  static Insertable<Tombstone> custom({
    Expression<String>? tbl,
    Expression<String>? uuid,
    Expression<DateTime>? deletedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tbl != null) 'tbl': tbl,
      if (uuid != null) 'uuid': uuid,
      if (deletedAt != null) 'deleted_at': deletedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  TombstonesCompanion copyWith(
      {Value<String>? tbl,
      Value<String>? uuid,
      Value<DateTime>? deletedAt,
      Value<int>? rowid}) {
    return TombstonesCompanion(
      tbl: tbl ?? this.tbl,
      uuid: uuid ?? this.uuid,
      deletedAt: deletedAt ?? this.deletedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tbl.present) {
      map['tbl'] = Variable<String>(tbl.value);
    }
    if (uuid.present) {
      map['uuid'] = Variable<String>(uuid.value);
    }
    if (deletedAt.present) {
      map['deleted_at'] = Variable<DateTime>(deletedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('TombstonesCompanion(')
          ..write('tbl: $tbl, ')
          ..write('uuid: $uuid, ')
          ..write('deletedAt: $deletedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $FogErasesTable extends FogErases
    with TableInfo<$FogErasesTable, FogErase> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $FogErasesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _tileXMeta = const VerificationMeta('tileX');
  @override
  late final GeneratedColumn<int> tileX = GeneratedColumn<int>(
      'tile_x', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _tileYMeta = const VerificationMeta('tileY');
  @override
  late final GeneratedColumn<int> tileY = GeneratedColumn<int>(
      'tile_y', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _zoomMeta = const VerificationMeta('zoom');
  @override
  late final GeneratedColumn<int> zoom = GeneratedColumn<int>(
      'zoom', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _layerIdMeta =
      const VerificationMeta('layerId');
  @override
  late final GeneratedColumn<int> layerId = GeneratedColumn<int>(
      'layer_id', aliasedName, false,
      type: DriftSqlType.int, requiredDuringInsert: true);
  static const VerificationMeta _maskMeta = const VerificationMeta('mask');
  @override
  late final GeneratedColumn<Uint8List> mask = GeneratedColumn<Uint8List>(
      'mask', aliasedName, false,
      type: DriftSqlType.blob, requiredDuringInsert: true);
  static const VerificationMeta _erasedAtMeta =
      const VerificationMeta('erasedAt');
  @override
  late final GeneratedColumn<DateTime> erasedAt = GeneratedColumn<DateTime>(
      'erased_at', aliasedName, false,
      type: DriftSqlType.dateTime, requiredDuringInsert: true);
  @override
  List<GeneratedColumn> get $columns =>
      [tileX, tileY, zoom, layerId, mask, erasedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'fog_erases';
  @override
  VerificationContext validateIntegrity(Insertable<FogErase> instance,
      {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('tile_x')) {
      context.handle(
          _tileXMeta, tileX.isAcceptableOrUnknown(data['tile_x']!, _tileXMeta));
    } else if (isInserting) {
      context.missing(_tileXMeta);
    }
    if (data.containsKey('tile_y')) {
      context.handle(
          _tileYMeta, tileY.isAcceptableOrUnknown(data['tile_y']!, _tileYMeta));
    } else if (isInserting) {
      context.missing(_tileYMeta);
    }
    if (data.containsKey('zoom')) {
      context.handle(
          _zoomMeta, zoom.isAcceptableOrUnknown(data['zoom']!, _zoomMeta));
    } else if (isInserting) {
      context.missing(_zoomMeta);
    }
    if (data.containsKey('layer_id')) {
      context.handle(_layerIdMeta,
          layerId.isAcceptableOrUnknown(data['layer_id']!, _layerIdMeta));
    } else if (isInserting) {
      context.missing(_layerIdMeta);
    }
    if (data.containsKey('mask')) {
      context.handle(
          _maskMeta, mask.isAcceptableOrUnknown(data['mask']!, _maskMeta));
    } else if (isInserting) {
      context.missing(_maskMeta);
    }
    if (data.containsKey('erased_at')) {
      context.handle(_erasedAtMeta,
          erasedAt.isAcceptableOrUnknown(data['erased_at']!, _erasedAtMeta));
    } else if (isInserting) {
      context.missing(_erasedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {tileX, tileY, zoom, layerId};
  @override
  FogErase map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return FogErase(
      tileX: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tile_x'])!,
      tileY: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}tile_y'])!,
      zoom: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}zoom'])!,
      layerId: attachedDatabase.typeMapping
          .read(DriftSqlType.int, data['${effectivePrefix}layer_id'])!,
      mask: attachedDatabase.typeMapping
          .read(DriftSqlType.blob, data['${effectivePrefix}mask'])!,
      erasedAt: attachedDatabase.typeMapping
          .read(DriftSqlType.dateTime, data['${effectivePrefix}erased_at'])!,
    );
  }

  @override
  $FogErasesTable createAlias(String alias) {
    return $FogErasesTable(attachedDatabase, alias);
  }
}

class FogErase extends DataClass implements Insertable<FogErase> {
  final int tileX;
  final int tileY;
  final int zoom;
  final int layerId;
  final Uint8List mask;
  final DateTime erasedAt;
  const FogErase(
      {required this.tileX,
      required this.tileY,
      required this.zoom,
      required this.layerId,
      required this.mask,
      required this.erasedAt});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['tile_x'] = Variable<int>(tileX);
    map['tile_y'] = Variable<int>(tileY);
    map['zoom'] = Variable<int>(zoom);
    map['layer_id'] = Variable<int>(layerId);
    map['mask'] = Variable<Uint8List>(mask);
    map['erased_at'] = Variable<DateTime>(erasedAt);
    return map;
  }

  FogErasesCompanion toCompanion(bool nullToAbsent) {
    return FogErasesCompanion(
      tileX: Value(tileX),
      tileY: Value(tileY),
      zoom: Value(zoom),
      layerId: Value(layerId),
      mask: Value(mask),
      erasedAt: Value(erasedAt),
    );
  }

  factory FogErase.fromJson(Map<String, dynamic> json,
      {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return FogErase(
      tileX: serializer.fromJson<int>(json['tileX']),
      tileY: serializer.fromJson<int>(json['tileY']),
      zoom: serializer.fromJson<int>(json['zoom']),
      layerId: serializer.fromJson<int>(json['layerId']),
      mask: serializer.fromJson<Uint8List>(json['mask']),
      erasedAt: serializer.fromJson<DateTime>(json['erasedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'tileX': serializer.toJson<int>(tileX),
      'tileY': serializer.toJson<int>(tileY),
      'zoom': serializer.toJson<int>(zoom),
      'layerId': serializer.toJson<int>(layerId),
      'mask': serializer.toJson<Uint8List>(mask),
      'erasedAt': serializer.toJson<DateTime>(erasedAt),
    };
  }

  FogErase copyWith(
          {int? tileX,
          int? tileY,
          int? zoom,
          int? layerId,
          Uint8List? mask,
          DateTime? erasedAt}) =>
      FogErase(
        tileX: tileX ?? this.tileX,
        tileY: tileY ?? this.tileY,
        zoom: zoom ?? this.zoom,
        layerId: layerId ?? this.layerId,
        mask: mask ?? this.mask,
        erasedAt: erasedAt ?? this.erasedAt,
      );
  FogErase copyWithCompanion(FogErasesCompanion data) {
    return FogErase(
      tileX: data.tileX.present ? data.tileX.value : this.tileX,
      tileY: data.tileY.present ? data.tileY.value : this.tileY,
      zoom: data.zoom.present ? data.zoom.value : this.zoom,
      layerId: data.layerId.present ? data.layerId.value : this.layerId,
      mask: data.mask.present ? data.mask.value : this.mask,
      erasedAt: data.erasedAt.present ? data.erasedAt.value : this.erasedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('FogErase(')
          ..write('tileX: $tileX, ')
          ..write('tileY: $tileY, ')
          ..write('zoom: $zoom, ')
          ..write('layerId: $layerId, ')
          ..write('mask: $mask, ')
          ..write('erasedAt: $erasedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
      tileX, tileY, zoom, layerId, $driftBlobEquality.hash(mask), erasedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is FogErase &&
          other.tileX == this.tileX &&
          other.tileY == this.tileY &&
          other.zoom == this.zoom &&
          other.layerId == this.layerId &&
          $driftBlobEquality.equals(other.mask, this.mask) &&
          other.erasedAt == this.erasedAt);
}

class FogErasesCompanion extends UpdateCompanion<FogErase> {
  final Value<int> tileX;
  final Value<int> tileY;
  final Value<int> zoom;
  final Value<int> layerId;
  final Value<Uint8List> mask;
  final Value<DateTime> erasedAt;
  final Value<int> rowid;
  const FogErasesCompanion({
    this.tileX = const Value.absent(),
    this.tileY = const Value.absent(),
    this.zoom = const Value.absent(),
    this.layerId = const Value.absent(),
    this.mask = const Value.absent(),
    this.erasedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  FogErasesCompanion.insert({
    required int tileX,
    required int tileY,
    required int zoom,
    required int layerId,
    required Uint8List mask,
    required DateTime erasedAt,
    this.rowid = const Value.absent(),
  })  : tileX = Value(tileX),
        tileY = Value(tileY),
        zoom = Value(zoom),
        layerId = Value(layerId),
        mask = Value(mask),
        erasedAt = Value(erasedAt);
  static Insertable<FogErase> custom({
    Expression<int>? tileX,
    Expression<int>? tileY,
    Expression<int>? zoom,
    Expression<int>? layerId,
    Expression<Uint8List>? mask,
    Expression<DateTime>? erasedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (tileX != null) 'tile_x': tileX,
      if (tileY != null) 'tile_y': tileY,
      if (zoom != null) 'zoom': zoom,
      if (layerId != null) 'layer_id': layerId,
      if (mask != null) 'mask': mask,
      if (erasedAt != null) 'erased_at': erasedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  FogErasesCompanion copyWith(
      {Value<int>? tileX,
      Value<int>? tileY,
      Value<int>? zoom,
      Value<int>? layerId,
      Value<Uint8List>? mask,
      Value<DateTime>? erasedAt,
      Value<int>? rowid}) {
    return FogErasesCompanion(
      tileX: tileX ?? this.tileX,
      tileY: tileY ?? this.tileY,
      zoom: zoom ?? this.zoom,
      layerId: layerId ?? this.layerId,
      mask: mask ?? this.mask,
      erasedAt: erasedAt ?? this.erasedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (tileX.present) {
      map['tile_x'] = Variable<int>(tileX.value);
    }
    if (tileY.present) {
      map['tile_y'] = Variable<int>(tileY.value);
    }
    if (zoom.present) {
      map['zoom'] = Variable<int>(zoom.value);
    }
    if (layerId.present) {
      map['layer_id'] = Variable<int>(layerId.value);
    }
    if (mask.present) {
      map['mask'] = Variable<Uint8List>(mask.value);
    }
    if (erasedAt.present) {
      map['erased_at'] = Variable<DateTime>(erasedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('FogErasesCompanion(')
          ..write('tileX: $tileX, ')
          ..write('tileY: $tileY, ')
          ..write('zoom: $zoom, ')
          ..write('layerId: $layerId, ')
          ..write('mask: $mask, ')
          ..write('erasedAt: $erasedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDb extends GeneratedDatabase {
  _$AppDb(QueryExecutor e) : super(e);
  $AppDbManager get managers => $AppDbManager(this);
  late final $TrackPointsTable trackPoints = $TrackPointsTable(this);
  late final $TrackLayersTable trackLayers = $TrackLayersTable(this);
  late final $FogTilesTable fogTiles = $FogTilesTable(this);
  late final $JournalEntriesTable journalEntries = $JournalEntriesTable(this);
  late final $ChatMessagesTable chatMessages = $ChatMessagesTable(this);
  late final $SongFavoritesTable songFavorites = $SongFavoritesTable(this);
  late final $PeerLocationsTable peerLocations = $PeerLocationsTable(this);
  late final $TombstonesTable tombstones = $TombstonesTable(this);
  late final $FogErasesTable fogErases = $FogErasesTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
        trackPoints,
        trackLayers,
        fogTiles,
        journalEntries,
        chatMessages,
        songFavorites,
        peerLocations,
        tombstones,
        fogErases
      ];
}

typedef $$TrackPointsTableCreateCompanionBuilder = TrackPointsCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  required double lat,
  required double lng,
  required DateTime time,
  Value<double?> accuracy,
  Value<double?> altitude,
  Value<double?> speed,
  Value<double?> width,
  required int layerId,
});
typedef $$TrackPointsTableUpdateCompanionBuilder = TrackPointsCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  Value<double> lat,
  Value<double> lng,
  Value<DateTime> time,
  Value<double?> accuracy,
  Value<double?> altitude,
  Value<double?> speed,
  Value<double?> width,
  Value<int> layerId,
});

class $$TrackPointsTableFilterComposer
    extends Composer<_$AppDb, $TrackPointsTable> {
  $$TrackPointsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get accuracy => $composableBuilder(
      column: $table.accuracy, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get altitude => $composableBuilder(
      column: $table.altitude, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get speed => $composableBuilder(
      column: $table.speed, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnFilters(column));
}

class $$TrackPointsTableOrderingComposer
    extends Composer<_$AppDb, $TrackPointsTable> {
  $$TrackPointsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get accuracy => $composableBuilder(
      column: $table.accuracy, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get altitude => $composableBuilder(
      column: $table.altitude, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get speed => $composableBuilder(
      column: $table.speed, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get width => $composableBuilder(
      column: $table.width, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnOrderings(column));
}

class $$TrackPointsTableAnnotationComposer
    extends Composer<_$AppDb, $TrackPointsTable> {
  $$TrackPointsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lng =>
      $composableBuilder(column: $table.lng, builder: (column) => column);

  GeneratedColumn<DateTime> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<double> get accuracy =>
      $composableBuilder(column: $table.accuracy, builder: (column) => column);

  GeneratedColumn<double> get altitude =>
      $composableBuilder(column: $table.altitude, builder: (column) => column);

  GeneratedColumn<double> get speed =>
      $composableBuilder(column: $table.speed, builder: (column) => column);

  GeneratedColumn<double> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get layerId =>
      $composableBuilder(column: $table.layerId, builder: (column) => column);
}

class $$TrackPointsTableTableManager extends RootTableManager<
    _$AppDb,
    $TrackPointsTable,
    TrackPoint,
    $$TrackPointsTableFilterComposer,
    $$TrackPointsTableOrderingComposer,
    $$TrackPointsTableAnnotationComposer,
    $$TrackPointsTableCreateCompanionBuilder,
    $$TrackPointsTableUpdateCompanionBuilder,
    (TrackPoint, BaseReferences<_$AppDb, $TrackPointsTable, TrackPoint>),
    TrackPoint,
    PrefetchHooks Function()> {
  $$TrackPointsTableTableManager(_$AppDb db, $TrackPointsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrackPointsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrackPointsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrackPointsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<double> lat = const Value.absent(),
            Value<double> lng = const Value.absent(),
            Value<DateTime> time = const Value.absent(),
            Value<double?> accuracy = const Value.absent(),
            Value<double?> altitude = const Value.absent(),
            Value<double?> speed = const Value.absent(),
            Value<double?> width = const Value.absent(),
            Value<int> layerId = const Value.absent(),
          }) =>
              TrackPointsCompanion(
            id: id,
            uuid: uuid,
            lat: lat,
            lng: lng,
            time: time,
            accuracy: accuracy,
            altitude: altitude,
            speed: speed,
            width: width,
            layerId: layerId,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required double lat,
            required double lng,
            required DateTime time,
            Value<double?> accuracy = const Value.absent(),
            Value<double?> altitude = const Value.absent(),
            Value<double?> speed = const Value.absent(),
            Value<double?> width = const Value.absent(),
            required int layerId,
          }) =>
              TrackPointsCompanion.insert(
            id: id,
            uuid: uuid,
            lat: lat,
            lng: lng,
            time: time,
            accuracy: accuracy,
            altitude: altitude,
            speed: speed,
            width: width,
            layerId: layerId,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TrackPointsTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $TrackPointsTable,
    TrackPoint,
    $$TrackPointsTableFilterComposer,
    $$TrackPointsTableOrderingComposer,
    $$TrackPointsTableAnnotationComposer,
    $$TrackPointsTableCreateCompanionBuilder,
    $$TrackPointsTableUpdateCompanionBuilder,
    (TrackPoint, BaseReferences<_$AppDb, $TrackPointsTable, TrackPoint>),
    TrackPoint,
    PrefetchHooks Function()>;
typedef $$TrackLayersTableCreateCompanionBuilder = TrackLayersCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  required String name,
  required int colorValue,
  Value<bool> visible,
  Value<String?> tag,
  required DateTime createdAt,
  Value<int?> pathColor,
  Value<double?> pathOpacity,
  Value<double?> pathWidth,
  Value<DateTime?> updatedAt,
});
typedef $$TrackLayersTableUpdateCompanionBuilder = TrackLayersCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  Value<String> name,
  Value<int> colorValue,
  Value<bool> visible,
  Value<String?> tag,
  Value<DateTime> createdAt,
  Value<int?> pathColor,
  Value<double?> pathOpacity,
  Value<double?> pathWidth,
  Value<DateTime?> updatedAt,
});

class $$TrackLayersTableFilterComposer
    extends Composer<_$AppDb, $TrackLayersTable> {
  $$TrackLayersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get visible => $composableBuilder(
      column: $table.visible, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get tag => $composableBuilder(
      column: $table.tag, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get pathColor => $composableBuilder(
      column: $table.pathColor, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get pathOpacity => $composableBuilder(
      column: $table.pathOpacity, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get pathWidth => $composableBuilder(
      column: $table.pathWidth, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$TrackLayersTableOrderingComposer
    extends Composer<_$AppDb, $TrackLayersTable> {
  $$TrackLayersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get name => $composableBuilder(
      column: $table.name, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get visible => $composableBuilder(
      column: $table.visible, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get tag => $composableBuilder(
      column: $table.tag, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
      column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get pathColor => $composableBuilder(
      column: $table.pathColor, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get pathOpacity => $composableBuilder(
      column: $table.pathOpacity, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get pathWidth => $composableBuilder(
      column: $table.pathWidth, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$TrackLayersTableAnnotationComposer
    extends Composer<_$AppDb, $TrackLayersTable> {
  $$TrackLayersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<int> get colorValue => $composableBuilder(
      column: $table.colorValue, builder: (column) => column);

  GeneratedColumn<bool> get visible =>
      $composableBuilder(column: $table.visible, builder: (column) => column);

  GeneratedColumn<String> get tag =>
      $composableBuilder(column: $table.tag, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get pathColor =>
      $composableBuilder(column: $table.pathColor, builder: (column) => column);

  GeneratedColumn<double> get pathOpacity => $composableBuilder(
      column: $table.pathOpacity, builder: (column) => column);

  GeneratedColumn<double> get pathWidth =>
      $composableBuilder(column: $table.pathWidth, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$TrackLayersTableTableManager extends RootTableManager<
    _$AppDb,
    $TrackLayersTable,
    TrackLayer,
    $$TrackLayersTableFilterComposer,
    $$TrackLayersTableOrderingComposer,
    $$TrackLayersTableAnnotationComposer,
    $$TrackLayersTableCreateCompanionBuilder,
    $$TrackLayersTableUpdateCompanionBuilder,
    (TrackLayer, BaseReferences<_$AppDb, $TrackLayersTable, TrackLayer>),
    TrackLayer,
    PrefetchHooks Function()> {
  $$TrackLayersTableTableManager(_$AppDb db, $TrackLayersTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TrackLayersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TrackLayersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TrackLayersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<String> name = const Value.absent(),
            Value<int> colorValue = const Value.absent(),
            Value<bool> visible = const Value.absent(),
            Value<String?> tag = const Value.absent(),
            Value<DateTime> createdAt = const Value.absent(),
            Value<int?> pathColor = const Value.absent(),
            Value<double?> pathOpacity = const Value.absent(),
            Value<double?> pathWidth = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              TrackLayersCompanion(
            id: id,
            uuid: uuid,
            name: name,
            colorValue: colorValue,
            visible: visible,
            tag: tag,
            createdAt: createdAt,
            pathColor: pathColor,
            pathOpacity: pathOpacity,
            pathWidth: pathWidth,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required String name,
            required int colorValue,
            Value<bool> visible = const Value.absent(),
            Value<String?> tag = const Value.absent(),
            required DateTime createdAt,
            Value<int?> pathColor = const Value.absent(),
            Value<double?> pathOpacity = const Value.absent(),
            Value<double?> pathWidth = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              TrackLayersCompanion.insert(
            id: id,
            uuid: uuid,
            name: name,
            colorValue: colorValue,
            visible: visible,
            tag: tag,
            createdAt: createdAt,
            pathColor: pathColor,
            pathOpacity: pathOpacity,
            pathWidth: pathWidth,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TrackLayersTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $TrackLayersTable,
    TrackLayer,
    $$TrackLayersTableFilterComposer,
    $$TrackLayersTableOrderingComposer,
    $$TrackLayersTableAnnotationComposer,
    $$TrackLayersTableCreateCompanionBuilder,
    $$TrackLayersTableUpdateCompanionBuilder,
    (TrackLayer, BaseReferences<_$AppDb, $TrackLayersTable, TrackLayer>),
    TrackLayer,
    PrefetchHooks Function()>;
typedef $$FogTilesTableCreateCompanionBuilder = FogTilesCompanion Function({
  required int tileX,
  required int tileY,
  required int zoom,
  required int layerId,
  required Uint8List bitmap,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$FogTilesTableUpdateCompanionBuilder = FogTilesCompanion Function({
  Value<int> tileX,
  Value<int> tileY,
  Value<int> zoom,
  Value<int> layerId,
  Value<Uint8List> bitmap,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

class $$FogTilesTableFilterComposer extends Composer<_$AppDb, $FogTilesTable> {
  $$FogTilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get tileX => $composableBuilder(
      column: $table.tileX, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get tileY => $composableBuilder(
      column: $table.tileY, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get zoom => $composableBuilder(
      column: $table.zoom, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get bitmap => $composableBuilder(
      column: $table.bitmap, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$FogTilesTableOrderingComposer
    extends Composer<_$AppDb, $FogTilesTable> {
  $$FogTilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get tileX => $composableBuilder(
      column: $table.tileX, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get tileY => $composableBuilder(
      column: $table.tileY, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get zoom => $composableBuilder(
      column: $table.zoom, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get bitmap => $composableBuilder(
      column: $table.bitmap, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$FogTilesTableAnnotationComposer
    extends Composer<_$AppDb, $FogTilesTable> {
  $$FogTilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get tileX =>
      $composableBuilder(column: $table.tileX, builder: (column) => column);

  GeneratedColumn<int> get tileY =>
      $composableBuilder(column: $table.tileY, builder: (column) => column);

  GeneratedColumn<int> get zoom =>
      $composableBuilder(column: $table.zoom, builder: (column) => column);

  GeneratedColumn<int> get layerId =>
      $composableBuilder(column: $table.layerId, builder: (column) => column);

  GeneratedColumn<Uint8List> get bitmap =>
      $composableBuilder(column: $table.bitmap, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$FogTilesTableTableManager extends RootTableManager<
    _$AppDb,
    $FogTilesTable,
    FogTile,
    $$FogTilesTableFilterComposer,
    $$FogTilesTableOrderingComposer,
    $$FogTilesTableAnnotationComposer,
    $$FogTilesTableCreateCompanionBuilder,
    $$FogTilesTableUpdateCompanionBuilder,
    (FogTile, BaseReferences<_$AppDb, $FogTilesTable, FogTile>),
    FogTile,
    PrefetchHooks Function()> {
  $$FogTilesTableTableManager(_$AppDb db, $FogTilesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FogTilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FogTilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FogTilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> tileX = const Value.absent(),
            Value<int> tileY = const Value.absent(),
            Value<int> zoom = const Value.absent(),
            Value<int> layerId = const Value.absent(),
            Value<Uint8List> bitmap = const Value.absent(),
            Value<DateTime> updatedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FogTilesCompanion(
            tileX: tileX,
            tileY: tileY,
            zoom: zoom,
            layerId: layerId,
            bitmap: bitmap,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int tileX,
            required int tileY,
            required int zoom,
            required int layerId,
            required Uint8List bitmap,
            required DateTime updatedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              FogTilesCompanion.insert(
            tileX: tileX,
            tileY: tileY,
            zoom: zoom,
            layerId: layerId,
            bitmap: bitmap,
            updatedAt: updatedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FogTilesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $FogTilesTable,
    FogTile,
    $$FogTilesTableFilterComposer,
    $$FogTilesTableOrderingComposer,
    $$FogTilesTableAnnotationComposer,
    $$FogTilesTableCreateCompanionBuilder,
    $$FogTilesTableUpdateCompanionBuilder,
    (FogTile, BaseReferences<_$AppDb, $FogTilesTable, FogTile>),
    FogTile,
    PrefetchHooks Function()>;
typedef $$JournalEntriesTableCreateCompanionBuilder = JournalEntriesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  required DateTime time,
  required double lat,
  required double lng,
  required String title,
  Value<String> richContent,
  Value<String> mediaPaths,
  required int layerId,
  Value<String> level,
  Value<String?> ownerPeerId,
  Value<DateTime?> updatedAt,
});
typedef $$JournalEntriesTableUpdateCompanionBuilder = JournalEntriesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  Value<DateTime> time,
  Value<double> lat,
  Value<double> lng,
  Value<String> title,
  Value<String> richContent,
  Value<String> mediaPaths,
  Value<int> layerId,
  Value<String> level,
  Value<String?> ownerPeerId,
  Value<DateTime?> updatedAt,
});

class $$JournalEntriesTableFilterComposer
    extends Composer<_$AppDb, $JournalEntriesTable> {
  $$JournalEntriesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get richContent => $composableBuilder(
      column: $table.richContent, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mediaPaths => $composableBuilder(
      column: $table.mediaPaths, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get ownerPeerId => $composableBuilder(
      column: $table.ownerPeerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnFilters(column));
}

class $$JournalEntriesTableOrderingComposer
    extends Composer<_$AppDb, $JournalEntriesTable> {
  $$JournalEntriesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get richContent => $composableBuilder(
      column: $table.richContent, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mediaPaths => $composableBuilder(
      column: $table.mediaPaths, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get level => $composableBuilder(
      column: $table.level, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get ownerPeerId => $composableBuilder(
      column: $table.ownerPeerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
      column: $table.updatedAt, builder: (column) => ColumnOrderings(column));
}

class $$JournalEntriesTableAnnotationComposer
    extends Composer<_$AppDb, $JournalEntriesTable> {
  $$JournalEntriesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<DateTime> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lng =>
      $composableBuilder(column: $table.lng, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get richContent => $composableBuilder(
      column: $table.richContent, builder: (column) => column);

  GeneratedColumn<String> get mediaPaths => $composableBuilder(
      column: $table.mediaPaths, builder: (column) => column);

  GeneratedColumn<int> get layerId =>
      $composableBuilder(column: $table.layerId, builder: (column) => column);

  GeneratedColumn<String> get level =>
      $composableBuilder(column: $table.level, builder: (column) => column);

  GeneratedColumn<String> get ownerPeerId => $composableBuilder(
      column: $table.ownerPeerId, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$JournalEntriesTableTableManager extends RootTableManager<
    _$AppDb,
    $JournalEntriesTable,
    JournalEntry,
    $$JournalEntriesTableFilterComposer,
    $$JournalEntriesTableOrderingComposer,
    $$JournalEntriesTableAnnotationComposer,
    $$JournalEntriesTableCreateCompanionBuilder,
    $$JournalEntriesTableUpdateCompanionBuilder,
    (JournalEntry, BaseReferences<_$AppDb, $JournalEntriesTable, JournalEntry>),
    JournalEntry,
    PrefetchHooks Function()> {
  $$JournalEntriesTableTableManager(_$AppDb db, $JournalEntriesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$JournalEntriesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$JournalEntriesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$JournalEntriesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<DateTime> time = const Value.absent(),
            Value<double> lat = const Value.absent(),
            Value<double> lng = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> richContent = const Value.absent(),
            Value<String> mediaPaths = const Value.absent(),
            Value<int> layerId = const Value.absent(),
            Value<String> level = const Value.absent(),
            Value<String?> ownerPeerId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              JournalEntriesCompanion(
            id: id,
            uuid: uuid,
            time: time,
            lat: lat,
            lng: lng,
            title: title,
            richContent: richContent,
            mediaPaths: mediaPaths,
            layerId: layerId,
            level: level,
            ownerPeerId: ownerPeerId,
            updatedAt: updatedAt,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required DateTime time,
            required double lat,
            required double lng,
            required String title,
            Value<String> richContent = const Value.absent(),
            Value<String> mediaPaths = const Value.absent(),
            required int layerId,
            Value<String> level = const Value.absent(),
            Value<String?> ownerPeerId = const Value.absent(),
            Value<DateTime?> updatedAt = const Value.absent(),
          }) =>
              JournalEntriesCompanion.insert(
            id: id,
            uuid: uuid,
            time: time,
            lat: lat,
            lng: lng,
            title: title,
            richContent: richContent,
            mediaPaths: mediaPaths,
            layerId: layerId,
            level: level,
            ownerPeerId: ownerPeerId,
            updatedAt: updatedAt,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$JournalEntriesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $JournalEntriesTable,
    JournalEntry,
    $$JournalEntriesTableFilterComposer,
    $$JournalEntriesTableOrderingComposer,
    $$JournalEntriesTableAnnotationComposer,
    $$JournalEntriesTableCreateCompanionBuilder,
    $$JournalEntriesTableUpdateCompanionBuilder,
    (JournalEntry, BaseReferences<_$AppDb, $JournalEntriesTable, JournalEntry>),
    JournalEntry,
    PrefetchHooks Function()>;
typedef $$ChatMessagesTableCreateCompanionBuilder = ChatMessagesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  required String peerId,
  required String author,
  required String content,
  required DateTime time,
  required bool outbound,
});
typedef $$ChatMessagesTableUpdateCompanionBuilder = ChatMessagesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  Value<String> peerId,
  Value<String> author,
  Value<String> content,
  Value<DateTime> time,
  Value<bool> outbound,
});

class $$ChatMessagesTableFilterComposer
    extends Composer<_$AppDb, $ChatMessagesTable> {
  $$ChatMessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get outbound => $composableBuilder(
      column: $table.outbound, builder: (column) => ColumnFilters(column));
}

class $$ChatMessagesTableOrderingComposer
    extends Composer<_$AppDb, $ChatMessagesTable> {
  $$ChatMessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get author => $composableBuilder(
      column: $table.author, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get content => $composableBuilder(
      column: $table.content, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get outbound => $composableBuilder(
      column: $table.outbound, builder: (column) => ColumnOrderings(column));
}

class $$ChatMessagesTableAnnotationComposer
    extends Composer<_$AppDb, $ChatMessagesTable> {
  $$ChatMessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get author =>
      $composableBuilder(column: $table.author, builder: (column) => column);

  GeneratedColumn<String> get content =>
      $composableBuilder(column: $table.content, builder: (column) => column);

  GeneratedColumn<DateTime> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);

  GeneratedColumn<bool> get outbound =>
      $composableBuilder(column: $table.outbound, builder: (column) => column);
}

class $$ChatMessagesTableTableManager extends RootTableManager<
    _$AppDb,
    $ChatMessagesTable,
    ChatMessage,
    $$ChatMessagesTableFilterComposer,
    $$ChatMessagesTableOrderingComposer,
    $$ChatMessagesTableAnnotationComposer,
    $$ChatMessagesTableCreateCompanionBuilder,
    $$ChatMessagesTableUpdateCompanionBuilder,
    (ChatMessage, BaseReferences<_$AppDb, $ChatMessagesTable, ChatMessage>),
    ChatMessage,
    PrefetchHooks Function()> {
  $$ChatMessagesTableTableManager(_$AppDb db, $ChatMessagesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ChatMessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ChatMessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ChatMessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<String> author = const Value.absent(),
            Value<String> content = const Value.absent(),
            Value<DateTime> time = const Value.absent(),
            Value<bool> outbound = const Value.absent(),
          }) =>
              ChatMessagesCompanion(
            id: id,
            uuid: uuid,
            peerId: peerId,
            author: author,
            content: content,
            time: time,
            outbound: outbound,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required String peerId,
            required String author,
            required String content,
            required DateTime time,
            required bool outbound,
          }) =>
              ChatMessagesCompanion.insert(
            id: id,
            uuid: uuid,
            peerId: peerId,
            author: author,
            content: content,
            time: time,
            outbound: outbound,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$ChatMessagesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $ChatMessagesTable,
    ChatMessage,
    $$ChatMessagesTableFilterComposer,
    $$ChatMessagesTableOrderingComposer,
    $$ChatMessagesTableAnnotationComposer,
    $$ChatMessagesTableCreateCompanionBuilder,
    $$ChatMessagesTableUpdateCompanionBuilder,
    (ChatMessage, BaseReferences<_$AppDb, $ChatMessagesTable, ChatMessage>),
    ChatMessage,
    PrefetchHooks Function()>;
typedef $$SongFavoritesTableCreateCompanionBuilder = SongFavoritesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  required String songId,
  required String title,
  required String artist,
  Value<String?> coverUrl,
  required String source,
  required DateTime addedAt,
  Value<double?> lat,
  Value<double?> lng,
});
typedef $$SongFavoritesTableUpdateCompanionBuilder = SongFavoritesCompanion
    Function({
  Value<int> id,
  Value<String> uuid,
  Value<String> songId,
  Value<String> title,
  Value<String> artist,
  Value<String?> coverUrl,
  Value<String> source,
  Value<DateTime> addedAt,
  Value<double?> lat,
  Value<double?> lng,
});

class $$SongFavoritesTableFilterComposer
    extends Composer<_$AppDb, $SongFavoritesTable> {
  $$SongFavoritesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
      column: $table.addedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnFilters(column));
}

class $$SongFavoritesTableOrderingComposer
    extends Composer<_$AppDb, $SongFavoritesTable> {
  $$SongFavoritesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get songId => $composableBuilder(
      column: $table.songId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title => $composableBuilder(
      column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get artist => $composableBuilder(
      column: $table.artist, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get coverUrl => $composableBuilder(
      column: $table.coverUrl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get source => $composableBuilder(
      column: $table.source, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
      column: $table.addedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnOrderings(column));
}

class $$SongFavoritesTableAnnotationComposer
    extends Composer<_$AppDb, $SongFavoritesTable> {
  $$SongFavoritesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<String> get songId =>
      $composableBuilder(column: $table.songId, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<String> get source =>
      $composableBuilder(column: $table.source, builder: (column) => column);

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lng =>
      $composableBuilder(column: $table.lng, builder: (column) => column);
}

class $$SongFavoritesTableTableManager extends RootTableManager<
    _$AppDb,
    $SongFavoritesTable,
    SongFavorite,
    $$SongFavoritesTableFilterComposer,
    $$SongFavoritesTableOrderingComposer,
    $$SongFavoritesTableAnnotationComposer,
    $$SongFavoritesTableCreateCompanionBuilder,
    $$SongFavoritesTableUpdateCompanionBuilder,
    (SongFavorite, BaseReferences<_$AppDb, $SongFavoritesTable, SongFavorite>),
    SongFavorite,
    PrefetchHooks Function()> {
  $$SongFavoritesTableTableManager(_$AppDb db, $SongFavoritesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SongFavoritesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SongFavoritesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SongFavoritesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<String> songId = const Value.absent(),
            Value<String> title = const Value.absent(),
            Value<String> artist = const Value.absent(),
            Value<String?> coverUrl = const Value.absent(),
            Value<String> source = const Value.absent(),
            Value<DateTime> addedAt = const Value.absent(),
            Value<double?> lat = const Value.absent(),
            Value<double?> lng = const Value.absent(),
          }) =>
              SongFavoritesCompanion(
            id: id,
            uuid: uuid,
            songId: songId,
            title: title,
            artist: artist,
            coverUrl: coverUrl,
            source: source,
            addedAt: addedAt,
            lat: lat,
            lng: lng,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            required String songId,
            required String title,
            required String artist,
            Value<String?> coverUrl = const Value.absent(),
            required String source,
            required DateTime addedAt,
            Value<double?> lat = const Value.absent(),
            Value<double?> lng = const Value.absent(),
          }) =>
              SongFavoritesCompanion.insert(
            id: id,
            uuid: uuid,
            songId: songId,
            title: title,
            artist: artist,
            coverUrl: coverUrl,
            source: source,
            addedAt: addedAt,
            lat: lat,
            lng: lng,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$SongFavoritesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $SongFavoritesTable,
    SongFavorite,
    $$SongFavoritesTableFilterComposer,
    $$SongFavoritesTableOrderingComposer,
    $$SongFavoritesTableAnnotationComposer,
    $$SongFavoritesTableCreateCompanionBuilder,
    $$SongFavoritesTableUpdateCompanionBuilder,
    (SongFavorite, BaseReferences<_$AppDb, $SongFavoritesTable, SongFavorite>),
    SongFavorite,
    PrefetchHooks Function()>;
typedef $$PeerLocationsTableCreateCompanionBuilder = PeerLocationsCompanion
    Function({
  Value<int> id,
  required String peerId,
  Value<String> peerName,
  required double lat,
  required double lng,
  required DateTime time,
});
typedef $$PeerLocationsTableUpdateCompanionBuilder = PeerLocationsCompanion
    Function({
  Value<int> id,
  Value<String> peerId,
  Value<String> peerName,
  Value<double> lat,
  Value<double> lng,
  Value<DateTime> time,
});

class $$PeerLocationsTableFilterComposer
    extends Composer<_$AppDb, $PeerLocationsTable> {
  $$PeerLocationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get peerName => $composableBuilder(
      column: $table.peerName, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnFilters(column));

  ColumnFilters<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnFilters(column));
}

class $$PeerLocationsTableOrderingComposer
    extends Composer<_$AppDb, $PeerLocationsTable> {
  $$PeerLocationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
      column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerId => $composableBuilder(
      column: $table.peerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get peerName => $composableBuilder(
      column: $table.peerName, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lat => $composableBuilder(
      column: $table.lat, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<double> get lng => $composableBuilder(
      column: $table.lng, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get time => $composableBuilder(
      column: $table.time, builder: (column) => ColumnOrderings(column));
}

class $$PeerLocationsTableAnnotationComposer
    extends Composer<_$AppDb, $PeerLocationsTable> {
  $$PeerLocationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get peerId =>
      $composableBuilder(column: $table.peerId, builder: (column) => column);

  GeneratedColumn<String> get peerName =>
      $composableBuilder(column: $table.peerName, builder: (column) => column);

  GeneratedColumn<double> get lat =>
      $composableBuilder(column: $table.lat, builder: (column) => column);

  GeneratedColumn<double> get lng =>
      $composableBuilder(column: $table.lng, builder: (column) => column);

  GeneratedColumn<DateTime> get time =>
      $composableBuilder(column: $table.time, builder: (column) => column);
}

class $$PeerLocationsTableTableManager extends RootTableManager<
    _$AppDb,
    $PeerLocationsTable,
    PeerLocation,
    $$PeerLocationsTableFilterComposer,
    $$PeerLocationsTableOrderingComposer,
    $$PeerLocationsTableAnnotationComposer,
    $$PeerLocationsTableCreateCompanionBuilder,
    $$PeerLocationsTableUpdateCompanionBuilder,
    (PeerLocation, BaseReferences<_$AppDb, $PeerLocationsTable, PeerLocation>),
    PeerLocation,
    PrefetchHooks Function()> {
  $$PeerLocationsTableTableManager(_$AppDb db, $PeerLocationsTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PeerLocationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PeerLocationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PeerLocationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> id = const Value.absent(),
            Value<String> peerId = const Value.absent(),
            Value<String> peerName = const Value.absent(),
            Value<double> lat = const Value.absent(),
            Value<double> lng = const Value.absent(),
            Value<DateTime> time = const Value.absent(),
          }) =>
              PeerLocationsCompanion(
            id: id,
            peerId: peerId,
            peerName: peerName,
            lat: lat,
            lng: lng,
            time: time,
          ),
          createCompanionCallback: ({
            Value<int> id = const Value.absent(),
            required String peerId,
            Value<String> peerName = const Value.absent(),
            required double lat,
            required double lng,
            required DateTime time,
          }) =>
              PeerLocationsCompanion.insert(
            id: id,
            peerId: peerId,
            peerName: peerName,
            lat: lat,
            lng: lng,
            time: time,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$PeerLocationsTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $PeerLocationsTable,
    PeerLocation,
    $$PeerLocationsTableFilterComposer,
    $$PeerLocationsTableOrderingComposer,
    $$PeerLocationsTableAnnotationComposer,
    $$PeerLocationsTableCreateCompanionBuilder,
    $$PeerLocationsTableUpdateCompanionBuilder,
    (PeerLocation, BaseReferences<_$AppDb, $PeerLocationsTable, PeerLocation>),
    PeerLocation,
    PrefetchHooks Function()>;
typedef $$TombstonesTableCreateCompanionBuilder = TombstonesCompanion Function({
  required String tbl,
  required String uuid,
  required DateTime deletedAt,
  Value<int> rowid,
});
typedef $$TombstonesTableUpdateCompanionBuilder = TombstonesCompanion Function({
  Value<String> tbl,
  Value<String> uuid,
  Value<DateTime> deletedAt,
  Value<int> rowid,
});

class $$TombstonesTableFilterComposer
    extends Composer<_$AppDb, $TombstonesTable> {
  $$TombstonesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get tbl => $composableBuilder(
      column: $table.tbl, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnFilters(column));
}

class $$TombstonesTableOrderingComposer
    extends Composer<_$AppDb, $TombstonesTable> {
  $$TombstonesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get tbl => $composableBuilder(
      column: $table.tbl, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get uuid => $composableBuilder(
      column: $table.uuid, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get deletedAt => $composableBuilder(
      column: $table.deletedAt, builder: (column) => ColumnOrderings(column));
}

class $$TombstonesTableAnnotationComposer
    extends Composer<_$AppDb, $TombstonesTable> {
  $$TombstonesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get tbl =>
      $composableBuilder(column: $table.tbl, builder: (column) => column);

  GeneratedColumn<String> get uuid =>
      $composableBuilder(column: $table.uuid, builder: (column) => column);

  GeneratedColumn<DateTime> get deletedAt =>
      $composableBuilder(column: $table.deletedAt, builder: (column) => column);
}

class $$TombstonesTableTableManager extends RootTableManager<
    _$AppDb,
    $TombstonesTable,
    Tombstone,
    $$TombstonesTableFilterComposer,
    $$TombstonesTableOrderingComposer,
    $$TombstonesTableAnnotationComposer,
    $$TombstonesTableCreateCompanionBuilder,
    $$TombstonesTableUpdateCompanionBuilder,
    (Tombstone, BaseReferences<_$AppDb, $TombstonesTable, Tombstone>),
    Tombstone,
    PrefetchHooks Function()> {
  $$TombstonesTableTableManager(_$AppDb db, $TombstonesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$TombstonesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$TombstonesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$TombstonesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> tbl = const Value.absent(),
            Value<String> uuid = const Value.absent(),
            Value<DateTime> deletedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              TombstonesCompanion(
            tbl: tbl,
            uuid: uuid,
            deletedAt: deletedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required String tbl,
            required String uuid,
            required DateTime deletedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              TombstonesCompanion.insert(
            tbl: tbl,
            uuid: uuid,
            deletedAt: deletedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$TombstonesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $TombstonesTable,
    Tombstone,
    $$TombstonesTableFilterComposer,
    $$TombstonesTableOrderingComposer,
    $$TombstonesTableAnnotationComposer,
    $$TombstonesTableCreateCompanionBuilder,
    $$TombstonesTableUpdateCompanionBuilder,
    (Tombstone, BaseReferences<_$AppDb, $TombstonesTable, Tombstone>),
    Tombstone,
    PrefetchHooks Function()>;
typedef $$FogErasesTableCreateCompanionBuilder = FogErasesCompanion Function({
  required int tileX,
  required int tileY,
  required int zoom,
  required int layerId,
  required Uint8List mask,
  required DateTime erasedAt,
  Value<int> rowid,
});
typedef $$FogErasesTableUpdateCompanionBuilder = FogErasesCompanion Function({
  Value<int> tileX,
  Value<int> tileY,
  Value<int> zoom,
  Value<int> layerId,
  Value<Uint8List> mask,
  Value<DateTime> erasedAt,
  Value<int> rowid,
});

class $$FogErasesTableFilterComposer
    extends Composer<_$AppDb, $FogErasesTable> {
  $$FogErasesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get tileX => $composableBuilder(
      column: $table.tileX, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get tileY => $composableBuilder(
      column: $table.tileY, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get zoom => $composableBuilder(
      column: $table.zoom, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get mask => $composableBuilder(
      column: $table.mask, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get erasedAt => $composableBuilder(
      column: $table.erasedAt, builder: (column) => ColumnFilters(column));
}

class $$FogErasesTableOrderingComposer
    extends Composer<_$AppDb, $FogErasesTable> {
  $$FogErasesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get tileX => $composableBuilder(
      column: $table.tileX, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get tileY => $composableBuilder(
      column: $table.tileY, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get zoom => $composableBuilder(
      column: $table.zoom, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get layerId => $composableBuilder(
      column: $table.layerId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get mask => $composableBuilder(
      column: $table.mask, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get erasedAt => $composableBuilder(
      column: $table.erasedAt, builder: (column) => ColumnOrderings(column));
}

class $$FogErasesTableAnnotationComposer
    extends Composer<_$AppDb, $FogErasesTable> {
  $$FogErasesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get tileX =>
      $composableBuilder(column: $table.tileX, builder: (column) => column);

  GeneratedColumn<int> get tileY =>
      $composableBuilder(column: $table.tileY, builder: (column) => column);

  GeneratedColumn<int> get zoom =>
      $composableBuilder(column: $table.zoom, builder: (column) => column);

  GeneratedColumn<int> get layerId =>
      $composableBuilder(column: $table.layerId, builder: (column) => column);

  GeneratedColumn<Uint8List> get mask =>
      $composableBuilder(column: $table.mask, builder: (column) => column);

  GeneratedColumn<DateTime> get erasedAt =>
      $composableBuilder(column: $table.erasedAt, builder: (column) => column);
}

class $$FogErasesTableTableManager extends RootTableManager<
    _$AppDb,
    $FogErasesTable,
    FogErase,
    $$FogErasesTableFilterComposer,
    $$FogErasesTableOrderingComposer,
    $$FogErasesTableAnnotationComposer,
    $$FogErasesTableCreateCompanionBuilder,
    $$FogErasesTableUpdateCompanionBuilder,
    (FogErase, BaseReferences<_$AppDb, $FogErasesTable, FogErase>),
    FogErase,
    PrefetchHooks Function()> {
  $$FogErasesTableTableManager(_$AppDb db, $FogErasesTable table)
      : super(TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$FogErasesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$FogErasesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$FogErasesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<int> tileX = const Value.absent(),
            Value<int> tileY = const Value.absent(),
            Value<int> zoom = const Value.absent(),
            Value<int> layerId = const Value.absent(),
            Value<Uint8List> mask = const Value.absent(),
            Value<DateTime> erasedAt = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) =>
              FogErasesCompanion(
            tileX: tileX,
            tileY: tileY,
            zoom: zoom,
            layerId: layerId,
            mask: mask,
            erasedAt: erasedAt,
            rowid: rowid,
          ),
          createCompanionCallback: ({
            required int tileX,
            required int tileY,
            required int zoom,
            required int layerId,
            required Uint8List mask,
            required DateTime erasedAt,
            Value<int> rowid = const Value.absent(),
          }) =>
              FogErasesCompanion.insert(
            tileX: tileX,
            tileY: tileY,
            zoom: zoom,
            layerId: layerId,
            mask: mask,
            erasedAt: erasedAt,
            rowid: rowid,
          ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ));
}

typedef $$FogErasesTableProcessedTableManager = ProcessedTableManager<
    _$AppDb,
    $FogErasesTable,
    FogErase,
    $$FogErasesTableFilterComposer,
    $$FogErasesTableOrderingComposer,
    $$FogErasesTableAnnotationComposer,
    $$FogErasesTableCreateCompanionBuilder,
    $$FogErasesTableUpdateCompanionBuilder,
    (FogErase, BaseReferences<_$AppDb, $FogErasesTable, FogErase>),
    FogErase,
    PrefetchHooks Function()>;

class $AppDbManager {
  final _$AppDb _db;
  $AppDbManager(this._db);
  $$TrackPointsTableTableManager get trackPoints =>
      $$TrackPointsTableTableManager(_db, _db.trackPoints);
  $$TrackLayersTableTableManager get trackLayers =>
      $$TrackLayersTableTableManager(_db, _db.trackLayers);
  $$FogTilesTableTableManager get fogTiles =>
      $$FogTilesTableTableManager(_db, _db.fogTiles);
  $$JournalEntriesTableTableManager get journalEntries =>
      $$JournalEntriesTableTableManager(_db, _db.journalEntries);
  $$ChatMessagesTableTableManager get chatMessages =>
      $$ChatMessagesTableTableManager(_db, _db.chatMessages);
  $$SongFavoritesTableTableManager get songFavorites =>
      $$SongFavoritesTableTableManager(_db, _db.songFavorites);
  $$PeerLocationsTableTableManager get peerLocations =>
      $$PeerLocationsTableTableManager(_db, _db.peerLocations);
  $$TombstonesTableTableManager get tombstones =>
      $$TombstonesTableTableManager(_db, _db.tombstones);
  $$FogErasesTableTableManager get fogErases =>
      $$FogErasesTableTableManager(_db, _db.fogErases);
}
