import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:mnn_runner_app/main.dart';

void main() {
  testWidgets('generate app screenshot', (tester) async {
    // Configure a desktop-like logical size; use devicePixelRatio for crispness
    tester.view.devicePixelRatio = 2.0;
    tester.view.physicalSize = const Size(1280, 800);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.devicePixelRatio = 1.0;
    });

    final boundaryKey = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundaryKey,
        child: const MyApp(),
      ),
    );
    // Let first layout and any initial async work settle
    await tester.pumpAndSettle(const Duration(milliseconds: 300));

    final boundary = boundaryKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 2.0);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();

    final out = File('docs/screenshot.png');
    await out.create(recursive: true);
    await out.writeAsBytes(bytes);

    // Sanity: ensure file is not empty
    expect(await out.length(), greaterThan(0));
  });
}

