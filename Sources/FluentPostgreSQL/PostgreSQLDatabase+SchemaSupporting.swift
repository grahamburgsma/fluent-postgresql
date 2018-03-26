import Async
import Foundation

/// Adds ability to create, update, and delete schemas using a `PostgreSQLDatabase`.
extension PostgreSQLDatabase: SchemaSupporting, IndexSupporting {
    /// See `SchemaSupporting.dataType`
    public static func dataType(for field: SchemaField<PostgreSQLDatabase>) -> String {
        var string: String
        if let knownSQLName = field.type.type.knownSQLName {
            string = knownSQLName
        } else {
            string = "VOID"
        }

        if field.type.size >= 0 {
            string += "(\(field.type.size))"
        }

        if field.isIdentifier {
            switch field.type.type {
            case .int8, .int4, .int2:
                if _globalEnableIdentityColumns {
                    string += " GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY"
                } else {
                    // not appending!
                    switch field.type.type {
                    case .int2: string = "SMALLSERIAL PRIMARY KEY"
                    case .int4: string = "SERIAL PRIMARY KEY"
                    case .int8: string = "BIGSERIAL PRIMARY KEY"
                    default: fatalError("should be unreachable")
                    }
                }
            default: string += " PRIMARY KEY"
            }
        } else if !field.isOptional {
            string += " NOT NULL"
        }

        if let d = field.type.default {
            string += " DEFAULT \(d)"
        }

        return string
    }

    /// See `SchemaSupporting.fieldType`
    public static func fieldType(for type: Any.Type) throws -> PostgreSQLColumn {
        if let representable = type as? PostgreSQLColumnStaticRepresentable.Type {
            return representable.postgreSQLColumn
        } else {
            throw PostgreSQLError(
                identifier: "fieldType",
                reason: "No PostgreSQL column type known for \(type).",
                suggestedFixes: [
                    "Conform \(type) to `PostgreSQLColumnStaticRepresentable` to specify field type or implement a custom migration.",
                    "Specify the `PostgreSQLColumn` manually using the schema builder in a migration."
                ],
                source: .capture()
            )
        }
    }

    /// See `SchemaSupporting.execute`
    public static func execute(schema: DatabaseSchema<PostgreSQLDatabase>, on connection: PostgreSQLConnection) -> Future<Void> {
        /// schema is changing, invalidate the table name cache
        PostgreSQLTableNameCache.invalidate(for: connection)

        return Future.flatMap(on: connection) {
            var schemaQuery = schema.makeSchemaQuery(dataTypeFactory: dataType)
            schema.applyReferences(to: &schemaQuery)
            let sqlString = PostgreSQLSQLSerializer().serialize(schema: schemaQuery)
            if let logger = connection.logger {
                logger.log(query: sqlString, parameters: [])
            }
            return try connection.query(sqlString).map(to: Void.self) { rows in
                assert(rows.count == 0)
            }.flatMap(to: Void.self) {
                /// handle indexes as separate query
                var indexFutures: [Future<Void>] = []
                for addIndex in schema.addIndexes {
                    let fields = addIndex.fields.map { "\"\($0.name)\"" }.joined(separator: ", ")
                    let name = addIndex.psqlName(for: schema.entity)
                    let add = connection.simpleQuery("CREATE \(addIndex.isUnique ? "UNIQUE " : "")INDEX \"\(name)\" ON \"\(schema.entity)\" (\(fields))").map(to: Void.self) { rows in
                        assert(rows.count == 0)
                    }
                    indexFutures.append(add)
                }
                for removeIndex in schema.removeIndexes {
                    let name = removeIndex.psqlName(for: schema.entity)
                    let remove = connection.simpleQuery("DROP INDEX \"\(name)\"").map(to: Void.self) { rows in
                        assert(rows.count == 0)
                    }
                    indexFutures.append(remove)
                }
                return indexFutures.flatten(on: connection)
            }
        }
    }
}

extension SchemaIndex {
    func psqlName(for entity: String) -> String {
        return "_fluent_index_\(entity)_" + fields.map { $0.name }.joined(separator: "_")
    }
}

