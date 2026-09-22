import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/foundation/app.dart';

void main() {
  testWidgets('toRoot opens an immersive page above the desktop shell', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Text('desktop navigation rail'),
              Expanded(
                child: Navigator(
                  onGenerateRoute: (_) => MaterialPageRoute<void>(
                    builder: (context) => Center(
                      child: FilledButton(
                        onPressed: () => context.toRoot(
                          () => Scaffold(
                            body: Builder(
                              builder: (readerContext) => Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Text('immersive reader'),
                                    FilledButton(
                                      onPressed: readerContext.pop,
                                      child: const Text('close reader'),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        child: const Text('open reader'),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(find.text('desktop navigation rail'), findsOneWidget);

    await tester.tap(find.text('open reader'));
    await tester.pumpAndSettle();

    expect(find.text('immersive reader'), findsOneWidget);
    expect(find.text('desktop navigation rail'), findsNothing);

    await tester.tap(find.text('close reader'));
    await tester.pumpAndSettle();

    expect(find.text('desktop navigation rail'), findsOneWidget);
  });
}
