@_exported import struct Foundation.URL

public struct PostgresConfig {
    public let address: () throws -> SocketAddress
    public let username: String
    public let password: String
    public let database: String?
    public let tlsConfig: TLSConfiguration?
    
    internal var _hostname: String?
    
    public init?(url: URL) {
        guard url.scheme == "postgres" else {
            return nil
        }
        guard let username = url.user else {
            return nil
        }
        guard let password = url.password else {
            return nil
        }
        guard let hostname = url.host else {
            return nil
        }
        guard let port = url.port else {
            return nil
        }
        
        let tlsConfig: TLSConfiguration?
        if url.query == "ssl=true" {
            tlsConfig = TLSConfiguration.forClient(certificateVerification: .none)
        } else {
            tlsConfig = nil
        }
        
        self.init(
            hostname: hostname,
            port: port,
            username: username,
            password: password,
            database: url.path.split(separator: "/").last.flatMap(String.init),
            tlsConfig: tlsConfig
        )
    }
    
    public init(
        hostname: String,
        port: Int = 5432,
        username: String,
        password: String,
        database: String? = nil,
        tlsConfig: TLSConfiguration? = nil
    ) {
        self.address = {
            return try SocketAddress.makeAddressResolvingHost(hostname, port: port)
        }
        self.username = username
        self.database = database
        self.password = password
        self.tlsConfig = tlsConfig
        self._hostname = hostname
    }
}

public struct PostgresConnectionSource: ConnectionPoolSource {
    public var eventLoop: EventLoop
    public let config: PostgresConfig
    
    public init(config: PostgresConfig, on eventLoop: EventLoop) {
        self.config = config
        self.eventLoop = eventLoop
    }
    
    public func makeConnection() -> EventLoopFuture<PostgresConnection> {
        let address: SocketAddress
        do {
            address = try self.config.address()
        } catch {
            return self.eventLoop.makeFailedFuture(error)
        }
        return PostgresConnection.connect(to: address, on: self.eventLoop).flatMap { conn in
            return conn.authenticate(
                username: self.config.username,
                database: self.config.database,
                password: self.config.password
            ).map { conn }
        }.flatMap { conn in
            if let tlsConfig = self.config.tlsConfig {
                return conn.requestTLS(using: tlsConfig, serverHostname: self.config._hostname).map { upgraded in
                    if !upgraded {
                        #warning("throw an error here?")
                        print("[Postgres] Server does not support TLS")
                    }
                    return conn
                }
            } else {
                return self.eventLoop.makeSucceededFuture(conn)
            }
        }
    }
}

extension PostgresConnection: ConnectionPoolItem {
    public var isClosed: Bool {
        #warning("implement is closed")
        return false
    }
}


extension PostgresRow: SQLRow {
    public func decode<D>(column: String, as type: D.Type) throws -> D where D : Decodable {
        guard let data = self.column(column) else {
            fatalError()
        }
        return try PostgresDataDecoder().decode(D.self, from: data)
    }
}

public struct SQLRaw: SQLExpression {
    public var string: String
    public init(_ string: String) {
        self.string = string
    }
    
    public func serialize(to serializer: inout SQLSerializer) {
        serializer.write(self.string)
    }
}

struct PostgresDialect: SQLDialect {
    private var bindOffset: Int
    
    init() {
        self.bindOffset = 0
    }
    
    var identifierQuote: SQLExpression {
        return SQLRaw("\"")
    }
    
    var literalStringQuote: SQLExpression {
        return SQLRaw("'")
    }
    
    mutating func nextBindPlaceholder() -> SQLExpression {
        self.bindOffset += 1
        return SQLRaw("$" + self.bindOffset.description)
    }
    
    func literalBoolean(_ value: Bool) -> SQLExpression {
        switch value {
        case false:
            return SQLRaw("false")
        case true:
            return SQLRaw("true")
        }
    }
    
    var autoIncrementClause: SQLExpression {
        return SQLRaw("GENERATED BY DEFAULT AS IDENTITY")
    }
}

extension PostgresConnection: SQLDatabase { }
extension SQLDatabase where Self: PostgresClient {
    public func sqlQuery(_ query: SQLExpression, _ onRow: @escaping (SQLRow) throws -> ()) -> EventLoopFuture<Void> {
        var serializer = SQLSerializer(dialect: PostgresDialect())
        query.serialize(to: &serializer)
        return self.query(serializer.sql, serializer.binds.map { encodable in
            return try! PostgresDataEncoder().encode(encodable)
        }) { row in
            try onRow(row)
        }
    }
}

#warning("TODO: move to NIOPostgres?")
extension ConnectionPool: PostgresClient where Source.Connection: PostgresClient {
    public var eventLoop: EventLoop {
        return self.source.eventLoop
    }
    
    public func send(_ request: PostgresRequestHandler) -> EventLoopFuture<Void> {
        return self.withConnection { $0.send(request) }
    }
}

#warning("TODO: move to SQLKit?")
extension ConnectionPool: SQLDatabase where Source.Connection: SQLDatabase {
    public func sqlQuery(_ query: SQLExpression, _ onRow: @escaping (SQLRow) throws -> ()) -> EventLoopFuture<Void> {
        return self.withConnection { $0.sqlQuery(query, onRow) }
    }
}

