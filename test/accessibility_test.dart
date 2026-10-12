import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_catalog/main.dart';

Future<void> tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 20; i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    if (Focus.of(tester.element(target)).hasFocus) return;
  }
  fail('Target was not reachable with Tab: $target');
}

void main() {
  testWidgets('320px and 2x text keeps content and recovery reachable', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 800));
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.binding.setSurfaceSize(null);
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(const PocketCatalogApp());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Fail next refresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fail next refresh'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Retry'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('keyboard can search, refresh, toggle offline and recover', (
    tester,
  ) async {
    await tester.pumpWidget(const PocketCatalogApp());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(
      tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus,
      isTrue,
    );
    await tester.enterText(find.byType(TextField), 'outdoor');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pumpAndSettle();
    expect(find.text('Trail notebook'), findsOneWidget);
    expect(find.text('Orbit desk lamp'), findsNothing);
    await tabTo(tester, find.text('Refresh'));
    final border = accessibleButtonStyle().side!.resolve({WidgetState.focused});
    expect(border!.width, 3);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(
      Focus.of(tester.element(find.byIcon(Icons.arrow_forward))).hasFocus,
      isTrue,
    );
    await tabTo(tester, find.text('Refresh'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('Loading catalog…'), findsOneWidget);
    await tester.pumpAndSettle();
    await tabTo(tester, find.text('Simulate offline'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    await tabTo(tester, find.text('Refresh'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Trail notebook'), findsOneWidget);
    await tabTo(tester, find.text('Simulate offline'));
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    // Inserting Retry after a failure must not move it to the end of focus order.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(Focus.of(tester.element(find.text('Retry'))).hasFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('semantics identify controls and announce loading and errors', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(const PocketCatalogApp());
    final loading = tester.getSemantics(find.text('Loading catalog…'));
    expect(loading.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
    await tester.pumpAndSettle();
    final search = tester.getSemantics(find.byType(TextField));
    expect(search.label, contains('Search the catalog'));
    expect(search.getSemanticsData().flagsCollection.isTextField, isTrue);
    final submit = tester.getSemantics(find.byTooltip('Search'));
    expect(submit.getSemanticsData().tooltip, 'Search');
    expect(submit.getSemanticsData().flagsCollection.isButton, isTrue);
    await tester.ensureVisible(find.text('Simulate offline'));
    await tester.pumpAndSettle();
    final toggle = tester.getSemantics(find.byType(SwitchListTile));
    expect(toggle.label, contains('Simulate offline'));
    expect(
      tester
          .getSemantics(find.byType(Switch))
          .getSemanticsData()
          .flagsCollection
          .isToggled
          .toBoolOrNull(),
      isFalse,
    );
    await tester.ensureVisible(find.text('Fail next refresh'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Fail next refresh'));
    await tester.pumpAndSettle();
    final error = find.text(
      'Refresh failed. Your saved session results are still available.',
    );
    await tester.ensureVisible(error);
    await tester.pumpAndSettle();
    expect(
      tester
          .getSemantics(error)
          .getSemanticsData()
          .flagsCollection
          .isLiveRegion,
      isTrue,
    );
    expect(
      tester
          .getSemantics(find.text('Retry'))
          .getSemanticsData()
          .flagsCollection
          .isButton,
      isTrue,
    );
    handle.dispose();
  });
}
