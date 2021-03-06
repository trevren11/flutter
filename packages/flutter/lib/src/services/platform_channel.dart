// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'message_codec.dart';
import 'message_codecs.dart';
import 'platform_messages.dart';

/// A named channel for communicating with platform plugins using asynchronous
/// message passing.
///
/// Messages are encoded into binary before being sent, and binary messages
/// received are decoded into Dart values. The [MessageCodec] used must be
/// compatible with the one used by the platform plugin. This can be achieved
/// by creating a `BasicMessageChannel` counterpart of this channel on the
/// platform side. The Dart type of messages sent and received is [T],
/// but only the values supported by the specified [MessageCodec] can be used.
/// The use of unsupported values should be considered programming errors, and
/// will result in exceptions being thrown. The null message is supported
/// for all codecs.
///
/// The logical identity of the channel is given by its name. Identically named
/// channels will interfere with each other's communication.
///
/// See: <https://flutter.io/platform-channels/>
class BasicMessageChannel<T> {
  /// Creates a [BasicMessageChannel] with the specified [name] and [codec].
  ///
  /// Neither [name] nor [codec] may be null.
  const BasicMessageChannel(this.name, this.codec);

  /// The logical channel on which communication happens, not null.
  final String name;

  /// The message codec used by this channel, not null.
  final MessageCodec<T> codec;

  /// Sends the specified [message] to the platform plugins on this channel.
  ///
  /// Returns a [Future] which completes to the received response, which may
  /// be null.
  Future<T> send(T message) async {
    return codec.decodeMessage(await BinaryMessages.send(name, codec.encodeMessage(message)));
  }

  /// Sets a callback for receiving messages from the platform plugins on this
  /// channel. Messages may be null.
  ///
  /// The given callback will replace the currently registered callback for this
  /// channel, if any. To remove the handler, pass null as the `handler`
  /// argument.
  ///
  /// The handler's return value is sent back to the platform plugins as a
  /// message reply. It may be null.
  void setMessageHandler(Future<T> handler(T message)) {
    if (handler == null) {
      BinaryMessages.setMessageHandler(name, null);
    } else {
      BinaryMessages.setMessageHandler(name, (ByteData message) async {
        return codec.encodeMessage(await handler(codec.decodeMessage(message)));
      });
    }
  }

  /// Sets a mock callback for intercepting messages sent on this channel.
  /// Messages may be null.
  ///
  /// The given callback will replace the currently registered mock callback for
  /// this channel, if any. To remove the mock handler, pass null as the
  /// `handler` argument.
  ///
  /// The handler's return value is used as a message reply. It may be null.
  ///
  /// This is intended for testing. Messages intercepted in this manner are not
  /// sent to platform plugins.
  void setMockMessageHandler(Future<T> handler(T message)) {
    if (handler == null) {
      BinaryMessages.setMockMessageHandler(name, null);
    } else {
      BinaryMessages.setMockMessageHandler(name, (ByteData message) async {
        return codec.encodeMessage(await handler(codec.decodeMessage(message)));
      });
    }
  }
}

/// A named channel for communicating with platform plugins using asynchronous
/// method calls.
///
/// Method calls are encoded into binary before being sent, and binary results
/// received are decoded into Dart values. The [MethodCodec] used must be
/// compatible with the one used by the platform plugin. This can be achieved
/// by creating a `MethodChannel` counterpart of this channel on the
/// platform side. The Dart type of arguments and results is `dynamic`,
/// but only values supported by the specified [MethodCodec] can be used.
/// The use of unsupported values should be considered programming errors, and
/// will result in exceptions being thrown. The null value is supported
/// for all codecs.
///
/// The logical identity of the channel is given by its name. Identically named
/// channels will interfere with each other's communication.
///
/// See: <https://flutter.io/platform-channels/>
class MethodChannel {
  /// Creates a [MethodChannel] with the specified [name].
  ///
  /// The [codec] used will be [StandardMethodCodec], unless otherwise
  /// specified.
  ///
  /// Neither [name] nor [codec] may be null.
  const MethodChannel(this.name, [this.codec = const StandardMethodCodec()]);

  /// The logical channel on which communication happens, not null.
  final String name;

  /// The message codec used by this channel, not null.
  final MethodCodec codec;

  /// Invokes a [method] on this channel with the specified [arguments].
  ///
  /// Returns a [Future] which completes to one of the following:
  ///
  /// * a result (possibly null), on successful invocation;
  /// * a [PlatformException], if the invocation failed in the platform plugin;
  /// * a [MissingPluginException], if the method has not been implemented by a
  ///   platform plugin.
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    assert(method != null);
    final dynamic result = await BinaryMessages.send(
      name,
      codec.encodeMethodCall(new MethodCall(method, arguments)),
    );
    if (result == null)
      throw new MissingPluginException("No implementation found for method $method on channel $name");
    return codec.decodeEnvelope(result);
  }

  /// Sets a callback for receiving method calls on this channel.
  ///
  /// The given callback will replace the currently registered callback for this
  /// channel, if any. To remove the handler, pass null as the
  /// `handler` argument.
  ///
  /// If the future returned by the handler completes with a result, that value
  /// is sent back to the platform plugin caller wrapped in a success envelope
  /// as defined by the [codec] of this channel. If the future completes with
  /// a [PlatformException], the fields of that exception will be used to
  /// populate an error envelope which is sent back instead. If the future
  /// completes with a [MissingPluginException], an empty reply is sent
  /// similarly to what happens if no method call handler has been set.
  /// Any other exception results in an error envelope being sent.
  void setMethodCallHandler(Future<dynamic> handler(MethodCall call)) {
    BinaryMessages.setMessageHandler(
      name,
      handler == null ? null : (ByteData message) => _handleAsMethodCall(message, handler),
    );
  }

  /// Sets a mock callback for intercepting method invocations on this channel.
  ///
  /// The given callback will replace the currently registered mock callback for
  /// this channel, if any. To remove the mock handler, pass null as the
  /// `handler` argument.
  ///
  /// Later calls to [invokeMethod] will result in a successful result,
  /// a [PlatformException] or a [MissingPluginException], determined by how
  /// the future returned by the mock callback completes. The [codec] of this
  /// channel is used to encode and decode values and errors.
  ///
  /// This is intended for testing. Method calls intercepted in this manner are
  /// not sent to platform plugins.
  void setMockMethodCallHandler(Future<dynamic> handler(MethodCall call)) {
    BinaryMessages.setMockMessageHandler(
      name,
      handler == null ? null : (ByteData message) => _handleAsMethodCall(message, handler),
    );
  }

  Future<ByteData> _handleAsMethodCall(ByteData message, Future<dynamic> handler(MethodCall call)) async {
    final MethodCall call = codec.decodeMethodCall(message);
    try {
      return codec.encodeSuccessEnvelope(await handler(call));
    } on PlatformException catch (e) {
      return codec.encodeErrorEnvelope(
        code: e.code,
        message: e.message,
        details: e.details,
      );
    } on MissingPluginException {
      return null;
    } catch (e) {
      return codec.encodeErrorEnvelope(code: 'error', message: e.toString(), details: null);
    }
  }
}

/// A [MethodChannel] that ignores missing platform plugins.
///
/// When [invokeMethod] fails to find the platform plugin, it returns null
/// instead of throwing an exception.
class OptionalMethodChannel extends MethodChannel {
  /// Creates a [MethodChannel] that ignores missing platform plugins.
  const OptionalMethodChannel(String name, [MethodCodec codec = const StandardMethodCodec()])
    : super(name, codec);

  @override
  Future<dynamic> invokeMethod(String method, [dynamic arguments]) async {
    try {
      return await super.invokeMethod(method, arguments);
    } on MissingPluginException {
      return null;
    }
  }
}

/// A named channel for communicating with platform plugins using event streams.
///
/// Stream setup requests are encoded into binary before being sent,
/// and binary events and errors received are decoded into Dart values.
/// The [MethodCodec] used must be compatible with the one used by the platform
/// plugin. This can be achieved by creating an `EventChannel` counterpart of
/// this channel on the platform side. The Dart type of events sent and received
/// is `dynamic`, but only values supported by the specified [MethodCodec] can
/// be used.
///
/// The logical identity of the channel is given by its name. Identically named
/// channels will interfere with each other's communication.
///
/// See: <https://flutter.io/platform-channels/>
class EventChannel {
  /// Creates an [EventChannel] with the specified [name].
  ///
  /// The [codec] used will be [StandardMethodCodec], unless otherwise
  /// specified.
  ///
  /// Neither [name] nor [codec] may be null.
  const EventChannel(this.name, [this.codec = const StandardMethodCodec()]);

  /// The logical channel on which communication happens, not null.
  final String name;

  /// The message codec used by this channel, not null.
  final MethodCodec codec;

  /// Sets up a broadcast stream for receiving events on this channel.
  ///
  /// Returns a broadcast [Stream] which emits events to listeners as follows:
  ///
  /// * a decoded data event (possibly null) for each successful event
  /// received from the platform plugin;
  /// * an error event containing a [PlatformException] for each error event
  /// received from the platform plugin;
  ///
  /// Errors occurring during stream activation or deactivation are reported
  /// through the [FlutterError] facility. Stream activation happens only when
  /// stream listener count changes from 0 to 1. Stream deactivation happens
  /// only when stream listener count changes from 1 to 0.
  Stream<dynamic> receiveBroadcastStream([dynamic arguments]) {
    final MethodChannel methodChannel = new MethodChannel(name, codec);
    StreamController<dynamic> controller;
    controller = new StreamController<dynamic>.broadcast(onListen: () async {
      BinaryMessages.setMessageHandler(name, (ByteData reply) async {
        if (reply == null)
          controller.close();
        else
          controller.add(codec.decodeEnvelope(reply));
      });
      try {
        await methodChannel.invokeMethod('listen', arguments);
      } catch (exception, stack) {
        FlutterError.reportError(new FlutterErrorDetails(
          exception: exception,
          stack: stack,
          library: 'services library',
          context: 'while activating platform stream on channel $name',
        ));
      }
    }, onCancel: () async {
      BinaryMessages.setMessageHandler(name, null);
      try {
        await methodChannel.invokeMethod('cancel', arguments);
      } catch (exception, stack) {
        FlutterError.reportError(new FlutterErrorDetails(
          exception: exception,
          stack: stack,
          library: 'services library',
          context: 'while de-activating platform stream on channel $name',
        ));
      }
    });
    return controller.stream;
  }
}
