//
//  Copyright © 2020 Square Inc. All rights reserved.
//

import Foundation

/**
 Writes values into data using the protocol buffer format in a stream-like fashion.
 */
public final class ProtoWriter {

    // MARK: - Properties

    private(set) var data: Data

    // MARK: - Life Cycle

    init(data: Data = .init()) {
        self.data = data
    }

    // MARK: - Public Methods - Encoding

    /** Encode an `enum` field */
    public func encode<T: RawRepresentable>(tag: UInt32, value: T?) throws where T.RawValue == UInt32 {
        guard let value = value else { return }
        encode(tag: tag, wireType: .varint, value: value) {
            writeVarint($0.rawValue)
        }
    }

    /** Encoded a repeated `enum` field */
    public func encode<T: RawRepresentable>(tag: UInt32, value: [T]?, packed: Bool = false) throws where T.RawValue == UInt32 {
        guard let value = value else { return }
        encode(tag: tag, wireType: .varint, value: value, packed: packed) {
            writeVarint($0.rawValue)
        }
    }

    /** Encode an integer field */
    public func encode<T: ProtoIntEncodable>(tag: UInt32, value: T?, encoding: ProtoIntEncoding = .variable) throws {
        guard let value = value else { return }
        let wireType = ProtoWriter.wireType(for: type(of: value), encoding: encoding)
        try encode(tag: tag, wireType: wireType, value: value) {
            try $0.encode(to: self, encoding: encoding)
        }
    }

    /** Encode a repeated integer field */
    public func encode<T: ProtoIntEncodable>(tag: UInt32, value: [T]?, encoding: ProtoIntEncoding = .variable, packed: Bool = false) throws {
        guard let value = value else { return }
        let wireType = ProtoWriter.wireType(for: T.self, encoding: encoding)
        try encode(tag: tag, wireType: wireType, value: value, packed: packed) {
            try $0.encode(to: self, encoding: encoding)
        }
    }

    /**
     Encode a field which has a single encoding mechanism (unlike integers).
     This includes most fields types, such as messages, strings, bytes, and floating point numbers.
     */
    public func encode(tag: UInt32, value: ProtoEncodable?) throws {
        guard let value = value else { return }

        let wireType = type(of: value).protoFieldWireType
        let key = ProtoWriter.makeFieldKey(tag: tag, wireType: wireType)

        writeVarint(key)
        if wireType == .lengthDelimited {
            try encodeLengthDelimited() { try value.encode(to: self) }
        } else {
            try value.encode(to: self)
        }
    }

    /** Encode a repeated field which has a single encoding mechanism, like messages, strings, and bytes. */
    public func encode<T: ProtoEncodable>(tag: UInt32, value: [T]?) throws {
        guard let value = value else { return }

        let wireType = type(of: value).Element.protoFieldWireType
        try encode(tag: tag, wireType: wireType, value: value, packed: false) { value in
            if wireType == .lengthDelimited {
                try encodeLengthDelimited() { try value.encode(to: self) }
            } else {
                try value.encode(to: self)
            }
        }
    }

    /**
     Encode a repeated `double` field.
     This method is distinct from the generic repeated `ProtoEncodable` one because doubles can be packed.
     */
    public func encode(tag: UInt32, value: [Double]?, packed: Bool = false) throws {
        guard let value = value else { return }

        try encode(tag: tag, wireType: .fixed64, value: value, packed: packed) { value in
            try value.encode(to: self)
        }
    }

    /**
     Encode a repeated `float` field.
     This method is distinct from the generic repeated `ProtoEncodable` one because floats can be packed.
     */
    public func encode(tag: UInt32, value: [Float]?, packed: Bool = false) throws {
        guard let value = value else { return }

        try encode(tag: tag, wireType: .fixed32, value: value, packed: packed) { value in
            try value.encode(to: self)
        }
    }

    // MARK: - Internal Methods - Writing Primitives

    /** Write arbitrary data */
    func write(_ data: Data) {
        self.data.append(data)
    }

    /** Write a single byte */
    func write(_ value: UInt8) {
        data.append(value)
    }

    /** Write a buffer of bytes */
    func write(_ buffer: UnsafeRawBufferPointer) {
        data.append(contentsOf: buffer)
    }

    /** Write a little-endian 32-bit integer.  */
    func writeFixed32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /** Write a little-endian 64-bit integer.  */
    func writeFixed64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    func writeVarint(_ value: UInt32) {
        data.writeVarint(value, at: data.count)
    }

    func writeVarint(_ value: UInt64) {
        data.writeVarint(value, at: data.count)
    }

    // MARK: - Private Methods - Field Keys

    /** Makes a tag value given a field number and wire type. */
    private static func makeFieldKey(tag: UInt32, wireType: FieldWireType) -> UInt32 {
        return (tag << Constants.tagFieldEncodingBits) | wireType.rawValue
    }

    private static func wireType<T: ProtoIntEncodable>(for valueType: T.Type, encoding: ProtoIntEncoding) -> FieldWireType {
        if encoding == .fixed {
            let size = MemoryLayout<T>.size
            if size == 4 {
                return .fixed32
            } else if size == 8 {
                return .fixed64
            } else {
                fatalError("Trying to encode integer of unexpected size \(size)")
            }
        } else {
            return .varint
        }
    }

    // MARK: - Private Methods - Field Encoder Helpers

    /** Encode a field */
    private func encode<T>(tag: UInt32, wireType: FieldWireType, value: T, encode: (T) throws -> Void) rethrows {
        let key = ProtoWriter.makeFieldKey(tag: tag, wireType: wireType)
        writeVarint(key)
        try encode(value)
    }

    /**
     Encode a generic repeated field.
     The public repeated field encoding methods should call this method to handle
     */
    private func encode<T>(tag: UInt32, wireType: FieldWireType, value: [T], packed: Bool, encode: (T) throws -> Void) rethrows {
        if packed {
            let key = ProtoWriter.makeFieldKey(tag: tag, wireType: .lengthDelimited)
            writeVarint(key)
            try encodeLengthDelimited {
                try value.forEach { try encode($0) }
            }
        } else {
            let key = ProtoWriter.makeFieldKey(tag: tag, wireType: wireType)
            try value.forEach {
                writeVarint(key)
                try encode($0)
            }
        }
    }

    private func encodeLengthDelimited(_ encode: () throws -> Void) rethrows {
        let startOffset = data.count
        let reservedSize = 2
        for _ in 0 ..< reservedSize {
            data.append(0)
        }

        try encode()

        let writtenCount = UInt32(data.count - startOffset - reservedSize)

        let sizeSize = Int(writtenCount.varintSize)
        if sizeSize < reservedSize {
            data.removeSubrange(startOffset + sizeSize ..< startOffset + reservedSize)
        } else if sizeSize != reservedSize {
            let zeros = [UInt8](repeating: 0, count: sizeSize - reservedSize)
            data.insert(contentsOf: zeros, at: startOffset + reservedSize)
        }

        data.writeVarint(writtenCount, at: startOffset)
    }

}
