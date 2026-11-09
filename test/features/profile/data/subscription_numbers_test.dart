import 'package:flutter_test/flutter_test.dart';
import 'package:hiddify/features/profile/data/profile_parser.dart';
import 'package:hiddify/features/profile/model/profile_entity.dart';

RemoteProfileEntity parseMetadata(Map<String, String> overrides) {
  final values = {'upload': '12', 'download': '34', 'total': '1024', 'expire': '1704054600', ...overrides};
  final result = ProfileParser.parse(
    tempFilePath: '',
    profile: ProfileEntity.remote(
      id: 'metadata-test',
      active: true,
      name: '',
      url: 'https://example.invalid/sub',
      lastUpdate: DateTime(2026),
      populatedHeaders: {
        'profile-title': 'Subscription',
        'subscription-userinfo': values.entries.map((e) => '${e.key}=${e.value}').join(';'),
      },
    ),
  );
  return result.match((failure) => throw TestFailure('optional metadata must not reject the profile: $failure'), (
    profile,
  ) {
    expect(profile.name, 'Subscription');
    expect(profile.active, isTrue);
    return profile as RemoteProfileEntity;
  });
}

void main() {
  final unlimitedExpiry = DateTime.fromMillisecondsSinceEpoch(ProfileParser.infiniteTimeThreshold * 1000);
  for (final value in ['NaN', 'Infinity', '-Infinity', '1e309', '-1', '-0.1']) {
    for (final field in ['upload', 'download']) {
      test('invalid required $field=$value drops only subscription statistics', () {
        expect(parseMetadata({field: value}).subInfo, isNull);
      });
    }
    test('invalid optional total=$value retains valid counters', () {
      final info = parseMetadata({'total': value}).subInfo!;
      expect(info.upload, 12);
      expect(info.download, 34);
      expect(info.total, ProfileParser.infiniteTrafficThreshold + 1);
      expect(info.expire, DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000));
    });
    test('invalid optional expire=$value uses the unlimited sentinel', () {
      final info = parseMetadata({'expire': value}).subInfo!;
      expect(info.upload, 12);
      expect(info.download, 34);
      expect(info.total, 1024);
      expect(info.expire, unlimitedExpiry);
    });
  }

  for (final value in ['8640000000001', '9223372036854775807', '1e100']) {
    test('out-of-range expiry $value cannot throw or wrap into the past', () {
      expect(parseMetadata({'expire': value}).subInfo!.expire, unlimitedExpiry);
    });
  }

  test('the largest supported expiry is accepted before multiplication', () {
    expect(
      parseMetadata({'expire': '8640000000000'}).subInfo!.expire,
      DateTime.fromMillisecondsSinceEpoch(8640000000000000),
    );
  });

  test('finite decimals keep their existing truncation behavior', () {
    final info = parseMetadata({
      'upload': '12.9',
      'download': '34.9',
      'total': '1024.9',
      'expire': '1704054600.9',
    }).subInfo!;
    expect(info.upload, 12);
    expect(info.download, 34);
    expect(info.total, 1024);
    expect(info.expire, DateTime.fromMillisecondsSinceEpoch(1704054600 * 1000));
  });

  test('zero traffic and unlimited total/expiry remain valid', () {
    final info = parseMetadata({'upload': '0', 'download': '-0.0', 'total': '0', 'expire': '0'}).subInfo!;
    expect(info.upload, 0);
    expect(info.download, 0);
    expect(info.total, ProfileParser.infiniteTrafficThreshold + 1);
    expect(info.expire, unlimitedExpiry);
  });

  test('unknown non-finite fields do not invalidate known metadata', () {
    final info = parseMetadata({'unknown': 'NaN'}).subInfo!;
    expect(info.upload, 12);
    expect(info.download, 34);
    expect(info.total, 1024);
  });
}
