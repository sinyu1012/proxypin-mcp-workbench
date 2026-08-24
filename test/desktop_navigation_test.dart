import 'package:flutter_test/flutter_test.dart';
import 'package:proxypin/ui/desktop/left_menus/navigation.dart';

void main() {
  test('capture destinations share the physical request page', () {
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.capture), 0);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.localCapture), 0);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.workbench), 1);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.favorites), 2);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.history), 3);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.toolbox), 4);
    expect(DesktopNavigationIndex.contentIndex(DesktopNavigationIndex.mcp), 5);
  });

  test('capture destinations and favorites keep the request detail panel', () {
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.capture), isTrue);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.localCapture), isTrue);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.favorites), isTrue);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.workbench), isFalse);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.history), isFalse);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.toolbox), isFalse);
    expect(DesktopNavigationIndex.usesRequestPanel(DesktopNavigationIndex.mcp), isFalse);
  });
}
