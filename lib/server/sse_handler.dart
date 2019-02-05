import 'dart:async';
import 'dart:convert';

import 'package:async/async.dart';
import 'package:logging/logging.dart';
import 'package:pedantic/pedantic.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:stream_channel/stream_channel.dart';

String _sseHeaders(String origin) => 'HTTP/1.1 200 OK\r\n'
    'Content-Type: text/event-stream\r\n'
    'Cache-Control: no-cache\r\n'
    'Connection: keep-alive\r\n'
    'Access-Control-Allow-Credentials: true\r\n'
    'Access-Control-Allow-Origin: $origin\r\n'
    '\r\n';

/// A bi-directional SSE connection between server and browser.
class SseConnection extends StreamChannelMixin<String> {
  final _incomingController = StreamController<String>();
  final _outgoingController = StreamController<String>();
  final _closeCompleter = Completer<Null>();
  final Sink _sink;
  final String _clientId;

  SseConnection(this._sink, this._clientId) {
    _outgoingController.stream.listen((data) {
      if (!_closeCompleter.isCompleted) {
        _sink.add('data: ${json.encode(data)}\n');
        _sink.add('\n');
      }
    });
  }

  Future get onClose => _closeCompleter.future;

  ///
  /// The message added to the sink has to be JSON encodable.
  @override
  StreamSink<String> get sink => _outgoingController.sink;

// Add messages to this [StreamSink] to send them to the server.
  /// [Stream] of messages sent from the server to this client.
  ///
  /// A message is a decoded JSON object.
  @override
  Stream<String> get stream => _incomingController.stream;

  void close() {
    if (!_closeCompleter.isCompleted) _closeCompleter.complete();
  }
}

/// [SseHandler] handles requests on a user defined path to create
/// two-way communications of JSON encodable data between server and clients.
///
/// A server sends messages to a client through an SSE channel, while
/// a client sends message to a server through HTTP POST requests.
class SseHandler {
  final _logger = Logger('SseHandler');
  final Uri _uri;

  final Set<SseConnection> _connections = Set<SseConnection>();

  final _connectionController = StreamController<SseConnection>();

  SseHandler(this._uri);

  StreamQueue<SseConnection> get connections =>
      StreamQueue(_connectionController.stream);

  shelf.Handler get handler => _handle;

  int get numberOfClients => _connections.length;

  shelf.Response _createSseConnection(shelf.Request req, String path) {
    req.hijack((channel) async {
      var sink = utf8.encoder.startChunkedConversion(channel.sink);
      sink.add(_sseHeaders(req.headers['origin']));
      var clientId = req.url.queryParameters['sseClientId'];
      var connection = SseConnection(sink, clientId);
      _connections.add(connection);
      unawaited(connection.onClose.then((_) {
        _connections.remove(connection);
      }));
      channel.stream.listen((_) {
        // SSE is unidirectional. Responses are handled through POST requests.
      }, onDone: () {
        connection.close();
      });
      _connectionController.add(connection);
    });
    return null;
  }

  String _getOriginalPath(shelf.Request req) => req.requestedUri.path;

  Future<shelf.Response> _handle(shelf.Request req) async {
    var path = _getOriginalPath(req);
    if (_uri.path != path) {
      return shelf.Response.notFound('');
    }

    if (req.headers['accept'] == 'text/event-stream' && req.method == 'GET') {
      return _createSseConnection(req, path);
    }

    if (req.headers['accept'] != 'text/event-stream' && req.method == 'POST') {
      return _handleIncomingMessage(req, path);
    }

    return shelf.Response.notFound('');
  }

  Future<shelf.Response> _handleIncomingMessage(
      shelf.Request req, String path) async {
    try {
      var clientId = req.url.queryParameters['sseClientId'];
      var message = await req.readAsString();
      var jsonObject = json.decode(message) as String;
      for (var connection in _connections) {
        if (connection._clientId == clientId) {
          connection._incomingController.add(jsonObject);
        }
      }
    } catch (e, st) {
      _logger.fine('Failed to handle incoming message. $e $st');
    }
    return shelf.Response.ok('', headers: {
      'access-control-allow-credentials': 'true',
      'access-control-allow-origin': req.headers['origin']
    });
  }
}
