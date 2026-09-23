import 'package:flutter_test/flutter_test.dart';
import 'package:venera_netmatic/network/cache.dart';

void main() {
  test('cached responses remain scoped to the same account credentials', () {
    expect(
      NetworkCacheManager.compareHeaders(
        {'authorization': 'Bearer account-a', 'token': 'a'},
        {'authorization': 'Bearer account-b', 'token': 'b'},
      ),
      isFalse,
    );
  });
}
