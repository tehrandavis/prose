#!/usr/bin/env python3
"""Exercise first-review preparation against Apple's published request schemas."""
import copy
import hashlib
import io
import json
from pathlib import Path
import unittest
from unittest.mock import Mock, patch

from appstore_connect import Release, relationship
from ipad_release import ROOT, metadata
from ipad_storefront import Storefront

FIXTURE = json.loads((Path(__file__).parent / 'fixtures/apple-storefront-schema.json').read_text())
SCHEMAS = FIXTURE['schemas']
REQUESTS = {
    'appStoreVersions': 'AppStoreVersionCreateRequest',
    'appStoreVersionLocalizations': 'AppStoreVersionLocalizationCreateRequest',
    'appStoreReviewDetails': 'AppStoreReviewDetailCreateRequest',
    'appInfoLocalizations': 'AppInfoLocalizationCreateRequest',
    'subscriptionGroups': 'SubscriptionGroupCreateRequest',
    'subscriptions': 'SubscriptionCreateRequest',
    'subscriptionVersions': 'SubscriptionVersionCreateRequest',
    'subscriptionGroupVersions': 'SubscriptionGroupVersionCreateRequest',
    'subscriptionLocalizations': 'SubscriptionLocalizationV2CreateRequest',
    'subscriptionGroupLocalizations': 'SubscriptionGroupLocalizationV2CreateRequest',
    'subscriptionPrices': 'SubscriptionPriceCreateRequest',
    'subscriptionIntroductoryOffers': 'SubscriptionIntroductoryOfferCreateRequest',
    'subscriptionAvailabilities': 'SubscriptionAvailabilityCreateRequest',
    'subscriptionAppStoreReviewScreenshots': 'SubscriptionAppStoreReviewScreenshotCreateRequest',
    'appScreenshotSets': 'AppScreenshotSetCreateRequest',
    'appScreenshots': 'AppScreenshotCreateRequest',
    'profiles': 'ProfileCreateRequest',
    'reviewSubmissions': 'ReviewSubmissionCreateRequest',
    'reviewSubmissionItems': 'ReviewSubmissionItemCreateRequest',
}


def validate(schema, value):
    if '$ref' in schema:
        return validate(SCHEMAS[schema['$ref'].split('/')[-1]], value)
    if value is None and schema.get('nullable'):
        return
    kind = schema.get('type')
    if kind == 'object':
        assert isinstance(value, dict), value
        assert set(schema.get('required', [])) <= value.keys(), ('missing', schema.get('required'), value)
        properties = schema.get('properties', {})
        assert not properties or value.keys() <= properties.keys(), ('unknown API fields', value)
        for key, child in value.items():
            validate(properties.get(key, {}), child)
    elif kind == 'array':
        assert isinstance(value, list)
        for child in value:
            validate(schema['items'], child)
    elif kind:
        assert type(value) is {'string': str, 'boolean': bool, 'integer': int, 'number': float}[kind], value
    if 'enum' in schema:
        assert value in schema['enum'], value


class Apple:
    """In-memory resource service; POST contracts come from Apple's schema."""
    def __init__(self):
        self.rows = {}
        self.posts = []
        self.automatic_app_prices = False
        self.app = '6818442294'
        self.put('apps', 'app', {'bundleId': 'com.tehrandavis.prose'})
        self.put('appInfos', 'info', {'state': 'PREPARE_FOR_SUBMISSION'}, {'app': relationship('apps', self.app)})
        for locale in ('en-US', 'zh-Hans'):
            self.put('appInfoLocalizations', locale, {'locale': locale, 'name': 'Prose',
                'privacyPolicyUrl': 'https://github.com/tehrandavis/prose/privacy.html' + ('?lang=zh' if locale == 'zh-Hans' else '')}, {'appInfo': relationship('appInfos', 'info')})
        self.put('appPriceSchedules', 'schedule', {})
        self.put('appPrices', 'free', {'startDate': None, 'endDate': None},
                 {'appPricePoint': relationship('appPricePoints', 'zero')})
        self.put('appPricePoints', 'zero', {'customerPrice': '0.00'})
        self.put('appStoreVersions', 'mac', {'platform': 'MAC_OS', 'versionString': '0.6.0', 'appVersionState': 'IN_REVIEW'})
        self.put('appStoreReviewDetails', 'contact', {'contactFirstName': 'Example', 'contactLastName': 'Reviewer',
            'contactPhone': '+10000000000', 'contactEmail': 'review@example.com'},
            {'appStoreVersion': relationship('appStoreVersions', 'mac')})
        self.put('subscriptionPricePoints', 'usd299', {'customerPrice': '2.99'},
                 {'territory': relationship('territories', 'USA')})
        self.put('territories', 'USA', {'currency': 'USD'})
        self.build = self.put('builds', 'build', {'version': '1', 'processingState': 'VALID',
            'expired': False, 'usesNonExemptEncryption': False, 'buildAudienceType': 'APP_STORE_ELIGIBLE'})

    def put(self, kind, identifier, attrs, rels=None):
        row = {'type': kind, 'id': identifier, 'attributes': copy.deepcopy(attrs), 'relationships': rels or {}}
        self.rows.setdefault(kind, {})[identifier] = row
        return row

    def request(self, method, path, payload=None):
        parts = path.strip('/').split('/')
        kind = parts[1]
        if method == 'POST':
            validate(SCHEMAS[REQUESTS[kind]], payload)
            self.posts.append((path, copy.deepcopy(payload)))
            data = payload['data']
            attrs = copy.deepcopy(data.get('attributes', {}))
            rels = copy.deepcopy(data.get('relationships', {}))
            if kind.endswith('Versions'):
                attrs.update({'state': 'PREPARE_FOR_SUBMISSION', 'appVersionState': 'PREPARE_FOR_SUBMISSION'})
            if kind == 'subscriptionPrices':
                point = self.rows['subscriptionPricePoints'][rels['subscriptionPricePoint']['data']['id']]
                rels['territory'] = point['relationships']['territory']
            return {'data': self.put(kind, 'created-' + str(len(self.posts)), attrs, rels)}
        if parts[1:3] == ['apps', self.app]:
            return {'data': self.rows['apps']['app']}
        row = self.rows[kind][parts[2]]
        if method == 'PATCH':
            if parts[-2:] == ['relationships', 'build']:
                row['relationships']['build'] = payload
            else:
                row['attributes'].update(payload['data']['attributes'])
            return {'data': row}
        if parts[-2:] == ['relationships', 'build']:
            return row['relationships'].get('build', {'data': None})
        return {'data': row}

    def patch(self, kind, identifier, attrs, api_version='v1'):
        return self.request('PATCH', f'/{api_version}/{kind}/{identifier}',
                            {'data': {'type': kind, 'id': identifier, 'attributes': attrs}})

    def list(self, path, **query):
        parts = path.strip('/').split('/')
        if len(parts) == 2:
            return list(self.rows.get(parts[1], {}).values())
        relation = parts[-1]
        aliases = {'pricePoints': 'subscriptionPricePoints', 'prices': 'subscriptionPrices',
                   'introductoryOffers': 'subscriptionIntroductoryOffers',
                   'versions': 'subscriptionVersions' if parts[1] == 'subscriptions' else 'subscriptionGroupVersions',
                   'localizations': 'subscriptionLocalizations' if parts[1] == 'subscriptionVersions' else 'subscriptionGroupLocalizations',
                   'manualPrices': 'appPrices', 'automaticPrices': 'appPrices'}
        kind = aliases.get(relation, relation)
        rows = list(self.rows.get(kind, {}).values())
        if relation == 'appStoreVersions':
            return [r for r in rows if r['attributes']['platform'] == query['filter[platform]']]
        if relation in ('manualPrices', 'automaticPrices'):
            if (relation == 'automaticPrices') != self.automatic_app_prices:
                return []
            rows = copy.deepcopy(rows)
            if 'appPricePoint' not in query.get('include', '').split(','):
                for row in rows:
                    # Apple omits relationship linkage unless explicitly included.
                    row['relationships'] = {'appPricePoint': {'links': {'related': 'price-point'}}}
            return rows
        if relation == 'pricePoints':
            return rows
        if relation == 'equalizations':
            return []
        # All remaining collection relationships are scoped by their parent ID.
        return [r for r in rows if any((v.get('data') or {}).get('id') == parts[2]
                                      for v in r['relationships'].values() if isinstance(v.get('data'), dict))]

    def optional(self, path):
        parts = path.strip('/').split('/')
        if parts[-1] == 'appPriceSchedule':
            return self.rows['appPriceSchedules']['schedule']
        mapping = {'appStoreReviewDetail': 'appStoreReviewDetails', 'subscriptionAvailability': 'subscriptionAvailabilities'}
        kind = mapping.get(parts[-1], parts[-1])
        return next((r for r in self.rows.get(kind, {}).values() if any(
            (v.get('data') or {}).get('id') == parts[2] for v in r['relationships'].values()
            if isinstance(v.get('data'), dict))), None)


class Preparation(unittest.TestCase):
    def setUp(self):
        self.apple = Apple()
        self.store = Storefront(Release(self.apple, self.apple.app, metadata(ROOT), 'IOS'))

    def test_first_review_preparation_and_partial_retry_follow_apple_contracts(self):
        with patch.object(self.store, 'upload_asset', return_value={'id': 'image'}):
            first = self.store.prepare(self.apple.build)
            count = len(self.apple.posts)
            second = self.store.prepare(self.apple.build)
        self.assertEqual(first['appStoreVersion']['id'], second['appStoreVersion']['id'])
        self.assertEqual(first['subscription']['id'], second['subscription']['id'])
        self.assertTrue(first['firstSubscription'])
        self.assertFalse(first['submitted'])
        self.assertEqual(len(self.apple.posts), count, 'A retry must reuse every created resource')
        self.assertEqual(first['subscription']['attributes']['productId'], 'com.tehrandavis.prose.ipad.monthly')
        self.assertEqual(len(self.apple.rows['subscriptionLocalizations']), 2)
        self.assertEqual(len(self.apple.rows['subscriptionGroupLocalizations']), 2)
        version = first['appStoreVersion']
        self.assertEqual(version['relationships']['build']['data']['id'], self.apple.build['id'])
        self.assertEqual(self.apple.rows['appInfoLocalizations']['en-US']['attributes']['name'], 'Prose')

    def test_manual_and_automatic_prices_require_a_free_download(self):
        for automatic in (False, True):
            self.apple.automatic_app_prices = automatic
            for amount in ('0.00', '1.99'):
                self.apple.rows['appPricePoints']['zero']['attributes']['customerPrice'] = amount
                with self.subTest(automatic=automatic, amount=amount):
                    if amount == '0.00':
                        self.store.app_information()
                    else:
                        with self.assertRaisesRegex(RuntimeError, 'free download'):
                            self.store.prepare(self.apple.build)
        self.assertNotIn('subscriptions', self.apple.rows)

    def test_missing_price_linkage_stops_without_requesting_a_none_identifier(self):
        self.apple.rows['appPrices']['free']['relationships'] = {}
        with patch.object(self.apple, 'request', wraps=self.apple.request) as request:
            with self.assertRaisesRegex(RuntimeError, 'cannot verify the free download price'):
                self.store.app_information()
        request.assert_not_called()
        self.assertFalse(self.apple.posts)

    def test_shared_mac_information_in_review_is_reused_without_changes(self):
        self.apple.rows['appInfos']['info']['attributes']['state'] = 'IN_REVIEW'
        before = copy.deepcopy(self.apple.rows['appInfoLocalizations'])
        with patch.object(self.store, 'upload_asset', return_value={'id': 'image'}):
            self.store.prepare(self.apple.build)
        self.assertEqual(self.apple.rows['appInfoLocalizations'], before)
        self.assertFalse(any(path == '/v1/appInfoLocalizations' for path, _ in self.apple.posts))

    def test_unexpected_shared_privacy_url_stops_without_changing_mac_metadata(self):
        self.apple.rows['appInfos']['info']['attributes']['state'] = 'IN_REVIEW'
        self.apple.rows['appInfoLocalizations']['zh-Hans']['attributes']['privacyPolicyUrl'] = 'https://example.com/privacy'
        before = copy.deepcopy(self.apple.rows['appInfoLocalizations'])
        with self.assertRaisesRegex(RuntimeError, 'Shared privacy URL differs'):
            self.store.app_information()
        self.assertEqual(self.apple.rows['appInfoLocalizations'], before)
        self.assertFalse(self.apple.posts)

    def test_shared_information_in_review_cannot_add_missing_locales(self):
        self.apple.rows['appInfos']['info']['attributes']['state'] = 'IN_REVIEW'
        del self.apple.rows['appInfoLocalizations']['zh-Hans']
        with self.assertRaisesRegex(RuntimeError, 'Missing shared App Info locale'):
            self.store.app_information()
        self.assertFalse(self.apple.posts)


class AssetUploads(unittest.TestCase):
    def setUp(self):
        self.client = Mock()
        self.store = Storefront(Release(self.client, '6818442294', metadata(ROOT), 'IOS'))
        self.path = ROOT / 'iPad/Storefront/screenshots/zh-dark-preview.png'
        self.content = self.path.read_bytes()
        self.row = {'type': 'appScreenshots', 'id': 'image', 'attributes': {
            'fileName': self.path.stem + '-' + hashlib.sha256(self.content).hexdigest()[:12] + '.png',
            'fileSize': len(self.content), 'assetDeliveryState': {'state': 'AWAITING_UPLOAD'},
            'uploadOperations': [{'url': 'https://apple-upload.example/image?signature=opaque',
                'method': 'PUT', 'offset': 0, 'length': len(self.content),
                'requestHeaders': [{'name': 'Content-Type', 'value': 'image/png'}]}]}}
        self.complete = copy.deepcopy(self.row)
        self.complete['attributes']['assetDeliveryState']['state'] = 'COMPLETE'
        self.client.request.return_value = {'data': self.complete}

    def test_reserved_upload_sends_only_image_bytes_then_commits_and_resumes(self):
        with patch('ipad_storefront.urllib.request.urlopen', return_value=io.BytesIO()) as transport:
            result = self.store.upload_asset('appScreenshots', self.path, {}, [self.row])
        request = transport.call_args.args[0]
        self.assertEqual(request.data, self.content)
        self.assertEqual(request.get_method(), 'PUT')
        self.assertEqual(dict(request.header_items()), {'Content-type': 'image/png'})
        self.client.patch.assert_called_once_with('appScreenshots', 'image', {
            'uploaded': True, 'sourceFileChecksum': hashlib.md5(self.content).hexdigest()})
        self.assertEqual(result, self.complete)
        self.client.reset_mock()
        with patch('ipad_storefront.urllib.request.urlopen') as transport:
            self.store.upload_asset('appScreenshots', self.path, {}, [self.complete], editable=False)
        transport.assert_not_called()
        self.client.patch.assert_not_called()

    def test_ready_review_missing_or_unprocessed_assets_never_mutate(self):
        for existing in ([], [self.row]):
            with self.subTest(existing=bool(existing)), self.assertRaisesRegex(RuntimeError, 'Ready-for-review'):
                self.store.upload_asset('appScreenshots', self.path, {}, existing, editable=False)
        self.client.request.assert_not_called()
        self.client.patch.assert_not_called()

    def test_invalid_storage_urls_and_ranges_stop_before_transmitting(self):
        for changes in ({'url': 'http://apple-upload.example/image'},
                        {'url': 'https://user:secret@apple-upload.example/image'},
                        {'url': 'https://apple-upload.example:8443/image'},
                        {'offset': -1}, {'length': len(self.content) + 1}):
            row = copy.deepcopy(self.row)
            row['attributes']['uploadOperations'][0].update(changes)
            with self.subTest(changes=changes), patch('ipad_storefront.urllib.request.urlopen') as transport:
                with self.assertRaises(RuntimeError):
                    self.store.upload_asset('appScreenshots', self.path, {}, [row])
                transport.assert_not_called()
        self.client.patch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
