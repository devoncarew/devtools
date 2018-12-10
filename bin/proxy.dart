import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:webkit_inspection_protocol/webkit_inspection_protocol.dart';

const bool temp = true;

// /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --user-data-dir=.data_dir --remote-debugging-port=9292

// TODO: handle breakpoints

void main(List<String> args) async {
  if (args.length != 2) {
    print('usage: dart bin/proxy <port-to-serve-on> <port-to-connect-to>');
    print('  proxy from a Chrome DevTools debugger connection to a VM Service '
        'protocol connection');
    exit(1);
  }

  final int serviceProtocolPort = int.parse(args[0]);
  final int devtoolsPort = int.parse(args[1]);

  final ChromeConnection chrome =
      new ChromeConnection('localhost', devtoolsPort);

  final HttpServer server =
      await HttpServer.bind(InternetAddress.loopbackIPv4, serviceProtocolPort);

  print('listening on ${server.port}');

  server.listen((HttpRequest request) {
    print(request);

    // todo:
    if (temp) {
      WebSocketTransformer.upgrade(request).then((WebSocket connection) {
        try {
          _handleConnection(connection, chrome);
        } catch (e) {
          print(e);
          connection.close();
        }
      });
    } else {
      // Do normal HTTP request processing.
    }
  });
}

void _handleConnection(WebSocket connection, ChromeConnection chrome) async {
  print(connection);

  final ChromeTab tab = await chrome.getTab((ChromeTab tab) {
    return !tab.isBackgroundPage && !tab.isChromeExtension;
  });

  print(tab);

  final WipConnection wip = await tab.connect();
  print(wip);

  final ServiceProtocolClient serviceProtocolClient =
      new ServiceProtocolClient(connection);

  final DebuggerProxy debuggerProxy =
      new DebuggerProxy(tab, wip, serviceProtocolClient);
}

class DebuggerProxy implements IdGenerator {
  DebuggerProxy(this.tab, this.wip, this.serviceProtocolClient) {
    wip.debugger.onScriptParsed.listen((ScriptParsedEvent e) {
      final WipScript script = e.script;

      final String url = script.sourceMapURL;
      if (url != null && url.isNotEmpty) {
        vm._addScript(this, script);
      }
    });

    wip.debugger.enable();
    // TODO:
    //wip.log.enable();

    vm = new ProxyVM(genId('vm'));
    vm.isolates.add(new ProxyIsolate(genId('isolate'), tab.url));

    _requestHandlers['getVM'] = getVM;
    _requestHandlers['streamListen'] = streamListen;
    _requestHandlers['getIsolate'] = getIsolate;
    _requestHandlers['getScripts'] = getScripts;
    _requestHandlers['getObject'] = getObject;

    Future<void>.delayed(const Duration(milliseconds: 200), () {
      // We delay a small amount in order to allow the script information to
      // be populated as events.
      serviceProtocolClient.onRequest.listen(_handleRequest);
    });
  }

  final ChromeTab tab;
  final WipConnection wip;
  final ServiceProtocolClient serviceProtocolClient;

  final Set<String> _streams = new Set<String>();

  int _objectId = 0;

  final Map<String, RequestHandler> _requestHandlers =
      <String, RequestHandler>{};

  ProxyVM vm;

  @override
  String genId([String prefix = 'object']) => '$prefix/${_objectId++}';

  void _handleRequest(ServiceProtocolRequest request) async {
    if (_requestHandlers.containsKey(request.method)) {
      final RequestHandler handler = _requestHandlers[request.method];

      try {
        final Response response = await handler(request.params);
        request.sendResponse(response);
      } catch (e, st) {
        // TODO:
        request.sendErrorResponse(
            new Error(0, 'error calling ${request.method}: $e'));
        print(st);
      }
    } else {
      // return error
      // TODO:
      request.sendErrorResponse(
          new Error(0, 'method not recognized: ${request.method}'));
    }
  }

  Future<Response> getVM(Map<dynamic, dynamic> params) async {
    return new Response(vm.toMap());
  }

  Future<Response> streamListen(Map<dynamic, dynamic> params) async {
    // TODO: send stream events
    final String streamId = params['streamId'];
    _streams.add(streamId);
    return new Response.ok();
  }

  Future<Response> getIsolate(Map<dynamic, dynamic> params) async {
    // todo: implement a 'requireString' method
    final String isolateId = params['isolateId'];
    final ProxyIsolate isolate = vm.findIsolate(isolateId);
    if (isolate == null) {
      throw new Error(0, 'isolateId $isolateId not found');
    }
    return new Response(isolate.toMap());
  }

  Future<Response> getScripts(Map<dynamic, dynamic> params) async {
    final String isolateId = params['isolateId'];
    final ProxyIsolate isolate = vm.findIsolate(isolateId);
    if (isolate == null) {
      throw new Error(0, 'isolateId $isolateId not found');
    }

    return new Response(<String, dynamic>{
      'type': 'ScriptList',
      'scripts': isolate
          .getScripts()
          .map((ProxyScript script) => script.toRefMap())
          .toList()
    });
  }

  // TODO: this implementation needs to be generalized
  Future<Response> getObject(Map<dynamic, dynamic> params) async {
    final String isolateId = params['isolateId'];
    final String objectId = params['objectId'];

    final ProxyIsolate isolate = vm.findIsolate(isolateId);
    if (isolate == null) {
      throw new Error(0, 'isolateId $isolateId not found');
    }

    // TODO: currently hardcoded for scripts

    for (ProxyScript script in isolate.getScripts()) {
      if (script.id == objectId) {
        await script.populateSource(this);
        return new Response(script.toMap());
      }
    }

    throw new Error(0, 'objectId $objectId not found');
  }
}

typedef RequestHandler = Future<Response> Function(
    Map<dynamic, dynamic> params);

class ServiceProtocolClient {
  ServiceProtocolClient(this.connection) {
    connection.listen((dynamic data) {
      if (data is String) {
        _processMessage(data);
      }
    });
  }

  final WebSocket connection;

  final StreamController<ServiceProtocolRequest> _requestController =
      new StreamController<ServiceProtocolRequest>();

  Stream<ServiceProtocolRequest> get onRequest => _requestController.stream;

  void _processMessage(String message) {
    // TODO:
    print('==> $message');

    try {
      final Map<dynamic, dynamic> data = jsonDecode(message);

      // TODO:
      _requestController.add(new ServiceProtocolRequest(this, data));
    } catch (e) {
      print('unable to decode "$message"');
    }
  }

  void _sendMessage(Map<String, dynamic> message) {
    final String data = jsonEncode(message);
    print('<== $data');
    connection.add(data);
  }
}

class ServiceProtocolRequest {
  ServiceProtocolRequest(this.client, this.data);

  final ServiceProtocolClient client;
  final Map<dynamic, dynamic> data;

  String get method => data['method'];

  String get id => data['id'];

  Map<String, dynamic> get params {
    final Map<dynamic, dynamic> m = data['params'];
    return m == null ? null : m.cast<String, dynamic>();
  }

  void sendResponse(Response result) {
    final Map<String, dynamic> map = <String, dynamic>{
      'id': id,
      'result': result.result,
    };
    client._sendMessage(map);
  }

  void sendErrorResponse(Error error) {
    final Map<String, dynamic> result = <String, dynamic>{
      'id': id,
      'error': error.toMap(),
    };

    client._sendMessage(result);
  }
}

class Response {
  Response(this.result);

  Response.ok() : result = <String, dynamic>{'type': 'Success'};

  final Map<String, dynamic> result;
}

class Error {
  Error(this.code, this.message);

  final int code;
  final String message;

  // final Map data;

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'code': code,
      'message': message,
    };
  }
}

abstract class ProxyObject {
  ProxyObject(this.id);

  final String id;

  String get type;

  Map<String, dynamic> toRefMap() {
    final Map<String, dynamic> map = <String, dynamic>{
      'type': '@$type',
      'id': id,
    };
    return map;
  }

  Map<String, dynamic> toMap() {
    final Map<String, dynamic> map = <String, dynamic>{
      'type': type,
      'id': id,
    };
    return map;
  }
}

class ProxyVM extends ProxyObject {
  ProxyVM(String id) : super(id);

  // TODO: what's meaningful here? The version of Dart the app was compiled with?
  final String version = Platform.version;

  @override
  String get type => 'VM';

  List<ProxyIsolate> isolates = <ProxyIsolate>[];

  ProxyIsolate get isolate => isolates.first;

  ProxyIsolate findIsolate(String isolateId) {
    for (ProxyIsolate isolate in isolates) {
      if (isolate.id == isolateId) {
        return isolate;
      }
    }
    return null;
  }

  @override
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> map = super.toMap();
    map['isolates'] =
        isolates.map((ProxyIsolate isolate) => isolate.toRefMap()).toList();
    map['version'] = version;
    return map;
  }

  void _addScript(IdGenerator idGenerator, WipScript script) =>
      isolate._addScript(idGenerator, script);
}

class ProxyIsolate extends ProxyObject {
  ProxyIsolate(String id, this.name) : super(id);

  final String name;

  @override
  String get type => 'Isolate';

  ProxyLibrary rootLib;
  List<ProxyLibrary> libraries = <ProxyLibrary>[];

  // TODO: populate breakpoints
  List<ProxyBreakpoint> breakpoints = <ProxyBreakpoint>[];

  List<ProxyScript> getScripts() =>
      libraries.expand((ProxyLibrary library) => library.scripts).toList();

  void _addScript(IdGenerator idGenerator, WipScript script) {
    print(script);

    final ProxyLibrary library = new ProxyLibrary.from(idGenerator, script);
    libraries.add(library);
    rootLib ??= library;
  }

  @override
  Map<String, dynamic> toRefMap() {
    final Map<String, dynamic> map = super.toRefMap();
    map['name'] = name;
    return map;
  }

  @override
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> map = super.toMap();
    map['name'] = name;
    if (rootLib != null) {
      map['rootLib'] = rootLib.toRefMap();
    }
    map['libraries'] =
        libraries.map((ProxyLibrary lib) => lib.toRefMap()).toList();
    map['breakpoints'] =
        breakpoints.map((ProxyBreakpoint bp) => bp.toRefMap()).toList();
    return map;
  }
}

abstract class IdGenerator {
  String genId([String prefix = 'object']);
}

class ProxyLibrary extends ProxyObject {
  ProxyLibrary.from(IdGenerator idGenerator, WipScript script)
      : uri = script.url,
        super(idGenerator.genId('library')) {
    scripts.add(new ProxyScript(
      idGenerator.genId('script'),
      script.url,
      this,
      script,
    ));
  }

  @override
  String get type => 'Library';

  final String uri;

  String get name => uri;

  List<ProxyScript> scripts = <ProxyScript>[];

  @override
  Map<String, dynamic> toRefMap() {
    final Map<String, dynamic> map = super.toRefMap();
    map['name'] = name;
    map['uri'] = uri;

    // TODO:

    return map;
  }
}

class ProxyBreakpoint extends ProxyObject {
  ProxyBreakpoint(String id) : super(id);

  @override
  String get type => 'Breakpoint';

// TODO: breakpointNumber, resolved, location

// TODO: toRefMap
}

class ProxyScript extends ProxyObject {
  ProxyScript(String id, this.uri, this.library, this.wipScript) : super(id);

  final String uri;
  final ProxyLibrary library;
  final WipScript wipScript;

  @override
  String get type => 'Script';

  String source;

  // TODO: we'll need to mock this up
  List<List<int>> tokenPosTable = <List<int>>[];

  Future<void> populateSource(DebuggerProxy proxy) async {
    if (source != null) {
      return;
    }
    source = await proxy.wip.debugger.getScriptSource(wipScript.scriptId);
  }

  @override
  Map<String, dynamic> toRefMap() {
    final Map<String, dynamic> map = super.toRefMap();
    map['uri'] = uri;
    return map;
  }

  @override
  Map<String, dynamic> toMap() {
    final Map<String, dynamic> map = super.toMap();
    map['uri'] = uri;
    map['library'] = library.toRefMap();
    map['source'] = source;
    map['tokenPosTable'] = tokenPosTable;
    return map;
  }
}
