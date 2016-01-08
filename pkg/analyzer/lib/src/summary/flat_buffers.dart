// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library analyzer.src.summary.flat_buffers;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/**
 * A pointer to some data.
 */
class BufferPointer {
  final ByteData _buffer;
  final int _offset;

  factory BufferPointer.fromBytes(List<int> byteList, [int offset = 0]) {
    Uint8List uint8List = _asUint8List(byteList);
    ByteData buf = new ByteData.view(uint8List.buffer);
    return new BufferPointer._(buf, uint8List.offsetInBytes + offset);
  }

  BufferPointer._(this._buffer, this._offset);

  BufferPointer derefObject() {
    int uOffset = _getUint32();
    return _advance(uOffset);
  }

  @override
  String toString() => _offset.toString();

  BufferPointer _advance(int delta) {
    return new BufferPointer._(_buffer, _offset + delta);
  }

  int _getInt32([int delta = 0]) =>
      _buffer.getInt32(_offset + delta, Endianness.LITTLE_ENDIAN);

  int _getInt64([int delta = 0]) =>
      _buffer.getInt64(_offset + delta, Endianness.LITTLE_ENDIAN);

  int _getInt8([int delta = 0]) => _buffer.getInt8(_offset + delta);

  int _getUint16([int delta = 0]) =>
      _buffer.getUint16(_offset + delta, Endianness.LITTLE_ENDIAN);

  int _getUint32([int delta = 0]) =>
      _buffer.getUint32(_offset + delta, Endianness.LITTLE_ENDIAN);

  /**
   * If the [byteList] is already a [Uint8List] return it.
   * Otherwise return a [Uint8List] copy of the [byteList].
   */
  static Uint8List _asUint8List(List<int> byteList) {
    if (byteList is Uint8List) {
      return byteList;
    } else {
      return new Uint8List.fromList(byteList);
    }
  }
}

/**
 * Class that helps building flat buffers.
 */
class Builder {
  final int initialSize;

  /**
   * The list of existing VTable(s).
   */
  final List<_VTable> _vTables = <_VTable>[];

  ByteData _buf;

  /**
   * The maximum alignment that has been seen so far.  If [_buf] has to be
   * reallocated in the future (to insert room at its start for more bytes) the
   * reallocation will need to be a multiple of this many bytes.
   */
  int _maxAlign;

  /**
   * The number of bytes that have been written to the buffer so far.  The
   * most recently written byte is this many bytes from the end of [_buf].
   */
  int _tail;

  /**
   * The location of the end of the current table, measured in bytes from the
   * end of [_buf], or `null` if a table is not currently being built.
   */
  int _currentTableEndTail;

  _VTable _currentVTable;

  Builder({this.initialSize: 1024}) {
    reset();
  }

  /**
   * Add the [field] with the given 32-bit signed integer [value].  The field is
   * not added if the [value] is equal to [def].
   */
  void addInt32(int field, int value, [int def]) {
    if (_currentVTable == null) {
      throw new StateError('Start a table before adding values.');
    }
    if (value != def) {
      int size = 4;
      _prepare(size, 1);
      _trackField(field);
      _setInt32AtTail(_buf, _tail, value);
    }
  }

  /**
   * Add the [field] with the given 64-bit signed integer [value].  The field is
   * not added if the [value] is equal to [def].
   */
  void addInt64(int field, int value, [int def]) {
    if (_currentVTable == null) {
      throw new StateError('Start a table before adding values.');
    }
    if (value != def) {
      int size = 8;
      _prepare(size, 1);
      _trackField(field);
      _setInt64AtTail(_buf, _tail, value);
    }
  }

  /**
   * Add the [field] with the given 8-bit signed integer [value].  The field is
   * not added if the [value] is equal to [def].
   */
  void addInt8(int field, int value, [int def]) {
    if (_currentVTable == null) {
      throw new StateError('Start a table before adding values.');
    }
    if (value != def) {
      int size = 1;
      _prepare(size, 1);
      _trackField(field);
      _buf.setInt8(_buf.lengthInBytes - _tail, value);
    }
  }

  /**
   * Add the [field] referencing an object with the given [offset].
   */
  void addOffset(int field, Offset offset) {
    if (_currentVTable == null) {
      throw new StateError('Start a table before adding values.');
    }
    if (offset != null) {
      _prepare(4, 1);
      _trackField(field);
      _setUint32AtTail(_buf, _tail, _tail - offset._tail);
    }
  }

  /**
   * End the current table and return its offset.
   */
  Offset endTable() {
    if (_currentVTable == null) {
      throw new StateError('Start a table before ending it.');
    }
    // Prepare the size of the current table.
    _currentVTable.tableSize = _tail - _currentTableEndTail;
    // Prepare for writing the VTable.
    _prepare(4, 1);
    int tableTail = _tail;
    // Prepare the VTable to use for the current table.
    int vTableTail;
    {
      _currentVTable.computeFieldOffsets(tableTail);
      // Try to find an existing compatible VTable.
      for (_VTable vTable in _vTables) {
        if (_currentVTable.canUseExistingVTable(vTable)) {
          vTableTail = vTable.tail;
        }
      }
      // Write a new VTable.
      if (vTableTail == null) {
        _prepare(2, _currentVTable.numOfUint16);
        vTableTail = _tail;
        _currentVTable.tail = vTableTail;
        _currentVTable.output(_buf, _buf.lengthInBytes - _tail);
        _vTables.add(_currentVTable);
      }
    }
    // Set the VTable offset.
    _setInt32AtTail(_buf, tableTail, vTableTail - tableTail);
    // Done with this table.
    _currentVTable = null;
    return new Offset(tableTail);
  }

  /**
   * Finish off the creation of the buffer.  The given [offset] is used as the
   * root object offset, and usually references directly or indirectly every
   * written object.
   */
  Uint8List finish(Offset offset) {
    _prepare(max(4, _maxAlign), 1);
    int alignedTail = _tail + ((-_tail) % _maxAlign);
    _setUint32AtTail(_buf, alignedTail, alignedTail - offset._tail);
    return _buf.buffer.asUint8List(_buf.lengthInBytes - alignedTail);
  }

  /**
   * This is a low-level method, it should not be invoked by clients.
   */
  Uint8List lowFinish() {
    int alignedTail = _tail + ((-_tail) % _maxAlign);
    return _buf.buffer.asUint8List(_buf.lengthInBytes - alignedTail);
  }

  /**
   * This is a low-level method, it should not be invoked by clients.
   */
  void lowReset() {
    _buf = new ByteData(initialSize);
    _maxAlign = 1;
    _tail = 0;
  }

  /**
   * This is a low-level method, it should not be invoked by clients.
   */
  void lowWriteUint32(int value) {
    _prepare(4, 1);
    _setUint32AtTail(_buf, _tail, value);
  }

  /**
   * This is a low-level method, it should not be invoked by clients.
   */
  void lowWriteUint64(int value) {
    _prepare(8, 1);
    _setUint64AtTail(_buf, _tail, value);
  }

  /**
   * This is a low-level method, it should not be invoked by clients.
   */
  void lowWriteUint8(int value) {
    _prepare(1, 1);
    _buf.setUint8(_buf.lengthInBytes - _tail, value);
  }

  /**
   * Reset the builder and make it ready for filling a new buffer.
   */
  void reset() {
    _buf = new ByteData(initialSize);
    _maxAlign = 1;
    _tail = 0;
    _currentVTable = null;
  }

  /**
   * Start a new table.  Must be finished with [endTable] invocation.
   */
  void startTable() {
    if (_currentVTable != null) {
      throw new StateError('Inline tables are not supported.');
    }
    _currentVTable = new _VTable();
    _currentTableEndTail = _tail;
  }

  /**
   * Write the given list of [values].
   */
  Offset writeList(List<Offset> values) {
    if (_currentVTable != null) {
      throw new StateError(
          'Cannot write a non-scalar value while writing a table.');
    }
    _prepare(4, 1 + values.length);
    Offset result = new Offset(_tail);
    int tail = _tail;
    _setUint32AtTail(_buf, tail, values.length);
    tail -= 4;
    for (Offset value in values) {
      _setUint32AtTail(_buf, tail, tail - value._tail);
      tail -= 4;
    }
    return result;
  }

  /**
   * Write the given list of signed 32-bit integer [values].
   */
  Offset writeListInt32(List<int> values) {
    if (_currentVTable != null) {
      throw new StateError(
          'Cannot write a non-scalar value while writing a table.');
    }
    _prepare(4, 1 + values.length);
    Offset result = new Offset(_tail);
    int tail = _tail;
    _setUint32AtTail(_buf, tail, values.length);
    tail -= 4;
    for (int value in values) {
      _setInt32AtTail(_buf, tail, value);
      tail -= 4;
    }
    return result;
  }

  /**
   * Write the given string [value] and return its [Offset], or `null` if
   * the [value] is equal to [def].
   */
  Offset<String> writeString(String value, [String def]) {
    if (_currentVTable != null) {
      throw new StateError(
          'Cannot write a non-scalar value while writing a table.');
    }
    if (value != def) {
      // TODO(scheglov) optimize for ASCII strings
      List<int> bytes = UTF8.encode(value);
      int length = bytes.length;
      _prepare(4, 1, additionalBytes: length);
      Offset<String> result = new Offset(_tail);
      _setUint32AtTail(_buf, _tail, length);
      int offset = _buf.lengthInBytes - _tail + 4;
      for (int i = 0; i < length; i++) {
        _buf.setUint8(offset++, bytes[i]);
      }
      return result;
    }
    return null;
  }

  /**
   * Prepare for writing the given [count] of scalars of the given [size].
   * Additionally allocate the specified [additionalBytes]. Update the current
   * tail pointer to point at the allocated space.
   */
  void _prepare(int size, int count, {int additionalBytes: 0}) {
    // Update the alignment.
    if (_maxAlign < size) {
      _maxAlign = size;
    }
    // Prepare amount of required space.
    int dataSize = size * count + additionalBytes;
    int alignDelta = (-(_tail + dataSize)) % size;
    int bufSize = alignDelta + dataSize;
    // Ensure that we have the required amount of space.
    {
      int oldCapacity = _buf.lengthInBytes;
      if (_tail + bufSize > oldCapacity) {
        int desiredNewCapacity = (oldCapacity + bufSize) * 2;
        int deltaCapacity = desiredNewCapacity - oldCapacity;
        deltaCapacity += (-deltaCapacity) % _maxAlign;
        int newCapacity = oldCapacity + deltaCapacity;
        ByteData newBuf = new ByteData(newCapacity);
        newBuf.buffer
            .asUint8List()
            .setAll(deltaCapacity, _buf.buffer.asUint8List());
        _buf = newBuf;
      }
    }
    // Update the tail pointer.
    _tail += bufSize;
  }

  /**
   * Record the offset of the given [field].
   */
  void _trackField(int field) {
    _currentVTable.addField(field, _tail);
  }

  static void _setInt32AtTail(ByteData _buf, int tail, int x) {
    _buf.setInt32(_buf.lengthInBytes - tail, x, Endianness.LITTLE_ENDIAN);
  }

  static void _setInt64AtTail(ByteData _buf, int tail, int x) {
    _buf.setInt64(_buf.lengthInBytes - tail, x, Endianness.LITTLE_ENDIAN);
  }

  static void _setUint32AtTail(ByteData _buf, int tail, int x) {
    _buf.setUint32(_buf.lengthInBytes - tail, x, Endianness.LITTLE_ENDIAN);
  }

  static void _setUint64AtTail(ByteData _buf, int tail, int x) {
    _buf.setUint64(_buf.lengthInBytes - tail, x, Endianness.LITTLE_ENDIAN);
  }
}

/**
 * The reader of 32-bit signed integers.
 */
class Int32Reader extends Reader<int> {
  const Int32Reader() : super();

  @override
  int get size => 4;

  @override
  int read(BufferPointer bp) => bp._getInt32();
}

/**
 * The reader of 64-bit signed integers.
 */
class Int64Reader extends Reader<int> {
  const Int64Reader() : super();

  @override
  int get size => 8;

  @override
  int read(BufferPointer bp) => bp._getInt64();
}

/**
 * The reader of 8-bit signed integers.
 */
class Int8Reader extends Reader<int> {
  const Int8Reader() : super();

  @override
  int get size => 1;

  @override
  int read(BufferPointer bp) => bp._getInt8();
}

/**
 * The reader of lists of objects.
 *
 * The returned unmodifiable lists lazily read objects on access.
 */
class ListReader<E> extends Reader<List<E>> {
  final Reader<E> _elementReader;

  const ListReader(this._elementReader);

  @override
  int get size => 4;

  @override
  List<E> read(BufferPointer bp) =>
      new _FbList<E>(_elementReader, bp.derefObject());
}

/**
 * The offset from the end of the buffer to a serialized object of the type [T].
 */
class Offset<T> {
  final int _tail;

  Offset(this._tail);
}

/**
 * Object that can read a value at a [BufferPointer].
 */
abstract class Reader<T> {
  const Reader();

  /**
   * The size of the value in bytes.
   */
  int get size;

  /**
   * Read the value at the given pointer.
   */
  T read(BufferPointer bp);

  /**
   * Read the value of the given [field] in the given [object].
   */
  T vTableGet(BufferPointer object, int field, [T defaultValue]) {
    int vTableSOffset = object._getInt32();
    BufferPointer vTable = object._advance(-vTableSOffset);
    int vTableSize = vTable._getUint16();
    int vTableFieldOffset = (1 + 1 + field) * 2;
    if (vTableFieldOffset < vTableSize) {
      int fieldOffsetInObject = vTable._getUint16(vTableFieldOffset);
      if (fieldOffsetInObject != 0) {
        BufferPointer fieldPointer = object._advance(fieldOffsetInObject);
        return read(fieldPointer);
      }
    }
    return defaultValue;
  }
}

/**
 * The reader of string values.
 */
class StringReader extends Reader<String> {
  const StringReader() : super();

  @override
  int get size => 4;

  @override
  String read(BufferPointer ref) {
    BufferPointer object = ref.derefObject();
    int length = object._getUint32();
    return UTF8
        .decode(ref._buffer.buffer.asUint8List(object._offset + 4, length));
  }
}

/**
 * An abstract reader for tables.
 */
abstract class TableReader<T extends TableReader<T>> extends Reader<T> {
  const TableReader();

  @override
  int get size => 4;

  /**
   * Return the [Reader] for reading fields of the object at [bp].
   */
  T createReader(BufferPointer bp);

  @override
  T read(BufferPointer bp) {
    bp = bp.derefObject();
    return createReader(bp);
  }
}

class _FbList<E> extends Object with ListMixin<E> implements List<E> {
  final Reader<E> elementReader;
  final BufferPointer bp;

  _FbList(this.elementReader, this.bp);

  @override
  int get length => bp._getUint32();

  @override
  void set length(int i) =>
      throw new StateError('Attempt to modify immutable list');

  @override
  E operator [](int i) {
    BufferPointer ref = bp._advance(4 + elementReader.size * i);
    return elementReader.read(ref);
  }

  @override
  void operator []=(int i, E e) =>
      throw new StateError('Attempt to modify immutable list');
}

/**
 * Class that describes the structure of a table.
 */
class _VTable {
  final List<int> fieldTails = <int>[];
  final List<int> fieldOffsets = <int>[];

  /**
   * The size of the table that uses this VTable.
   */
  int tableSize;

  /**
   * The tail of this VTable.  It is used to share the same VTable between
   * multiple tables of identical structure.
   */
  int tail;

  int get numOfUint16 => 1 + 1 + fieldTails.length;

  void addField(int field, int offset) {
    while (fieldTails.length <= field) {
      fieldTails.add(null);
    }
    fieldTails[field] = offset;
  }

  /**
   * Return `true` if the [existing] VTable can be used instead of this.
   */
  bool canUseExistingVTable(_VTable existing) {
    assert(tail == null);
    assert(existing.tail != null);
    if (tableSize == existing.tableSize &&
        fieldOffsets.length == existing.fieldOffsets.length) {
      for (int i = 0; i < fieldOffsets.length; i++) {
        if (fieldOffsets[i] != existing.fieldOffsets[i]) {
          return false;
        }
      }
      return true;
    }
    return false;
  }

  /**
   * Fill the [fieldOffsets] field.
   */
  void computeFieldOffsets(int tableTail) {
    assert(fieldOffsets.isEmpty);
    for (int fieldTail in fieldTails) {
      int fieldOffset = fieldTail == null ? 0 : tableTail - fieldTail;
      fieldOffsets.add(fieldOffset);
    }
  }

  /**
   * Outputs this VTable to [buf], which is is expected to be aligned to 16-bit
   * and have at least [numOfUint16] 16-bit words available.
   */
  void output(ByteData buf, int bufOffset) {
    // VTable size.
    buf.setUint16(bufOffset, numOfUint16 * 2, Endianness.LITTLE_ENDIAN);
    bufOffset += 2;
    // Table size.
    buf.setUint16(bufOffset, tableSize, Endianness.LITTLE_ENDIAN);
    bufOffset += 2;
    // Field offsets.
    for (int fieldOffset in fieldOffsets) {
      buf.setUint16(bufOffset, fieldOffset, Endianness.LITTLE_ENDIAN);
      bufOffset += 2;
    }
  }
}
