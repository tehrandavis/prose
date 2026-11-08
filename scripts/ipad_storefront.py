"""Idempotent iPad storefront preparation and subsequent App Review submission.

Apple requires the FIRST subscription to be submitted with an app binary in
App Store Connect's website. CI prepares that review and reports the requirement;
after initial approval, tags submit the iOS version through the current API.
API payloads follow Apple's App Store Connect OpenAPI 4.5 (September 2026).
"""
import base64
import datetime
from decimal import Decimal
import hashlib
import json
from pathlib import Path
import time
import urllib.parse
import urllib.request

from appstore_connect import EDITABLE, relationship, state
from ipad_release import BUNDLE, ROOT, validate_profile

APPROVED = {'APPROVED', 'ACCEPTED'}
PENDING = {'WAITING_FOR_REVIEW', 'IN_REVIEW'}
REVIEW_NOTES = (
    'iPad-only writing and typesetting app. No login is required. Open Settings > '
    'Subscription to purchase or restore. Eligible new subscribers receive two '
    'weeks free, then USD 2.99/month in the USA. Use an App Review sandbox Apple '
    'Account to test. Creating/editing require a subscription; existing documents '
    'remain readable and exportable, including full source and assets, after expiry. '
    'Mac remains free. Rendering runs locally. Additional Typst packages use HTTPS.'
)


def rel_id(row, name):
    return (row.get('relationships', {}).get(name, {}).get('data') or {}).get('id')


def unique(rows, description):
    if len(rows) > 1:
        raise RuntimeError('Ambiguous ' + description)
    return rows[0] if rows else None


class Storefront:
    def __init__(self, release):
        self.release, self.client = release, release.client
        self.store = release.metadata['storefront']
        if str(release.app) != self.store['app_store_app_id']:
            raise RuntimeError('iPad storefront belongs to a different App Store app')

    def create(self, kind, attrs=None, rels=None, api_version='v1'):
        data = {'type': kind}
        if attrs is not None:
            data['attributes'] = attrs
        if rels:
            data['relationships'] = rels
        return self.client.request('POST', f'/{api_version}/{kind}', {'data': data})['data']

    def profile(self, identity, destination):
        """Reuse/create a profile for the existing certificate; never rotate keys."""
        certificates = self.client.list('/v1/certificates', **{'limit': 200})
        cert = unique([row for row in certificates if
                       hashlib.sha1(base64.b64decode(row['attributes']['certificateContent'])).hexdigest().upper()
                       == identity.upper()], 'signing certificate')
        if not cert:
            raise RuntimeError('The existing signing certificate is absent from the Apple account')
        bundles = self.client.list('/v1/bundleIds', **{'filter[identifier]': BUNDLE, 'limit': 200})
        bundle = unique([row for row in bundles if row['attributes']['platform'] in ('IOS', 'UNIVERSAL')], 'iOS bundle ID')
        if not bundle:
            raise RuntimeError('Register the existing Prose bundle ID for iOS and iCloud first')
        profiles = self.client.list(f"/v1/bundleIds/{bundle['id']}/profiles", limit=200)
        import plistlib
        import subprocess
        for row in profiles:
            if (row['attributes']['profileType'] != 'IOS_APP_STORE'
                    or row['attributes']['profileState'] != 'ACTIVE'):
                continue
            content = base64.b64decode(row['attributes']['profileContent'])
            decoded = plistlib.loads(subprocess.check_output(['security', 'cms', '-D'], input=content))
            try:
                validate_profile(decoded, identity)
            except ValueError:
                continue
            destination.write_bytes(content)
            return
        row = self.create('profiles', {'name': 'Prose iPad App Store ' + identity[:12],
                          'profileType': 'IOS_APP_STORE'}, {
                          'bundleId': relationship('bundleIds', bundle['id']),
                          'certificates': {'data': [{'type': 'certificates', 'id': cert['id']}]}})
        content = base64.b64decode(row['attributes']['profileContent'])
        decoded = plistlib.loads(subprocess.check_output(['security', 'cms', '-D'], input=content))
        validate_profile(decoded, identity)
        destination.write_bytes(content)

    def upload_asset(self, kind, path, rels, existing, editable=True):
        """Resume a reservation using Apple's signed upload URLs, without API JWT."""
        content = path.read_bytes()
        checksum = hashlib.md5(content).hexdigest()
        filename = path.stem + '-' + hashlib.sha256(content).hexdigest()[:12] + path.suffix
        row = unique([item for item in existing if item['attributes']['fileName'] == filename], path.name)
        if not editable and (not row or row['attributes'].get('assetDeliveryState', {}).get('state') != 'COMPLETE'):
            raise RuntimeError('Ready-for-review screenshot differs from source: ' + path.name)
        if row and row['attributes'].get('sourceFileChecksum') not in (None, checksum):
            raise RuntimeError('Existing screenshot has different content: ' + path.name)
        if not row:
            row = self.create(kind, {'fileName': filename, 'fileSize': len(content)}, rels)
        attrs = row['attributes']
        if attrs.get('fileSize') != len(content):
            raise RuntimeError('Existing screenshot has different size: ' + path.name)
        delivery = attrs.get('assetDeliveryState', {}).get('state')
        if delivery not in ('COMPLETE', 'UPLOAD_COMPLETE'):
            if delivery not in ('AWAITING_UPLOAD', 'UPLOADING'):
                raise RuntimeError(f'Screenshot needs attention: {delivery}')
            operations = attrs.get('uploadOperations', [])
            if not operations:
                raise RuntimeError('Missing screenshot upload reservation')
            for operation in operations:
                url = urllib.parse.urlparse(operation['url'])
                if url.scheme != 'https' or url.username or url.password or url.port not in (None, 443):
                    raise RuntimeError('Unexpected Apple asset upload URL')
                # Apple returns an opaque signed storage URL. Only transmit the
                # screenshot bytes and returned headers; never our API credential.
                offset, length = operation['offset'], operation['length']
                if offset < 0 or length <= 0 or offset + length > len(content):
                    raise RuntimeError('Invalid screenshot upload range')
                request = urllib.request.Request(operation['url'], method=operation['method'],
                    data=content[offset:offset + length],
                    headers={h['name']: h['value'] for h in operation.get('requestHeaders', [])})
                with urllib.request.urlopen(request, timeout=60) as response:
                    response.read()
            self.client.patch(kind, row['id'], {'uploaded': True, 'sourceFileChecksum': checksum})
        deadline = time.monotonic() + 180
        while True:
            result = self.client.request('GET', f"/v1/{kind}/{row['id']}")['data']
            delivery = result['attributes'].get('assetDeliveryState', {}).get('state')
            if delivery == 'COMPLETE':
                return result
            if delivery == 'FAILED' or time.monotonic() > deadline:
                raise RuntimeError('Apple screenshot processing failed or timed out: ' + path.name)
            time.sleep(5)

    def versioned_localizations(self, parent_kind, parent_id, version_kind, locale_kind, locales):
        versions = self.client.list(f'/v1/{parent_kind}/{parent_id}/versions', limit=200)
        pending = [v for v in versions if v['attributes']['state'] in PENDING]
        if pending:
            raise RuntimeError('Subscription metadata is already in review; finish that review first')
        drafts = [v for v in versions if v['attributes']['state'] in EDITABLE | {'READY_FOR_REVIEW'}]
        draft = unique(drafts, 'subscription metadata draft')
        approved = any(v['attributes']['state'] in APPROVED for v in versions)
        if not draft and approved:
            return None, True
        parent_rel = 'subscription' if parent_kind == 'subscriptions' else 'subscriptionGroup'
        if not draft:
            draft = self.create(version_kind, rels={parent_rel: relationship(parent_kind, parent_id)})
        rows = self.client.list(f"/v1/{version_kind}/{draft['id']}/localizations", limit=200)
        by_locale = {row['attributes']['locale']: row for row in rows}
        for locale, fields in locales.items():
            attrs = {'locale': locale, **fields}
            row = by_locale.get(locale)
            if row:
                if any(row['attributes'].get(k) != v for k, v in attrs.items()):
                    if draft['attributes']['state'] == 'READY_FOR_REVIEW':
                        raise RuntimeError('Ready-for-review subscription localization differs from source')
                    self.client.patch(locale_kind, row['id'], fields, api_version='v2')
            else:
                self.create(locale_kind, attrs, {'version': relationship(version_kind, draft['id'])}, 'v2')
        return draft, approved

    def subscription(self):
        config = self.store['subscription']
        groups = self.client.list(f'/v1/apps/{self.release.app}/subscriptionGroups', limit=200)
        group = unique([g for g in groups if g['attributes']['referenceName'] == config['group_reference_name']],
                       'Prose iPad subscription group')
        # Discover product IDs across ALL groups before creating anything.
        found = []
        for candidate in groups:
            products = self.client.list(f"/v1/subscriptionGroups/{candidate['id']}/subscriptions", limit=200)
            found.extend((candidate, p) for p in products if p['attributes']['productId'] == config['product_id'])
        product_match = unique(found, 'Prose iPad product ID')
        if product_match and (not group or product_match[0]['id'] != group['id']):
            raise RuntimeError('The iPad product ID belongs to a different subscription group')
        if not group:
            group = self.create('subscriptionGroups', {'referenceName': config['group_reference_name']},
                                {'app': relationship('apps', self.release.app)})
        product = product_match[1] if product_match else self.create('subscriptions', {
            'name': config['reference_name'], 'productId': config['product_id'],
            'subscriptionPeriod': config['period'], 'familySharable': False,
            'groupLevel': 1, 'reviewNote': REVIEW_NOTES}, {'group': relationship('subscriptionGroups', group['id'])})
        if product['attributes']['subscriptionPeriod'] != config['period']:
            raise RuntimeError('Existing product has a different subscription period')
        self.prices_and_trial(product['id'])
        subscription_version, approved = self.versioned_localizations(
            'subscriptions', product['id'], 'subscriptionVersions', 'subscriptionLocalizations', config['localizations'])
        group_version, _ = self.versioned_localizations(
            'subscriptionGroups', group['id'], 'subscriptionGroupVersions', 'subscriptionGroupLocalizations',
            {locale: {'name': fields['name']} for locale, fields in config['localizations'].items()})
        path = ROOT / 'iPad/Storefront/screenshots/subscription.png'
        existing = self.client.optional(f"/v1/subscriptions/{product['id']}/appStoreReviewScreenshot")
        if existing:
            expected_name = path.stem + '-' + hashlib.sha256(path.read_bytes()).hexdigest()[:12] + path.suffix
            if existing['attributes']['fileName'] != expected_name:
                raise RuntimeError('A different subscription review screenshot exists; reconcile it before release')
        self.upload_asset('subscriptionAppStoreReviewScreenshots', path,
                          {'subscription': relationship('subscriptions', product['id'])}, [existing] if existing else [])
        return product, subscription_version, group_version, approved

    def prices_and_trial(self, product_id):
        config = self.store['subscription']
        points = self.client.list(f'/v1/subscriptions/{product_id}/pricePoints',
                                  **{'filter[territory]': 'USA', 'limit': 8000})
        base = unique([p for p in points if Decimal(p['attributes']['customerPrice']) == Decimal(config['base_price'])],
                      'USD 2.99 monthly price point')
        if not base:
            raise RuntimeError('Apple has no USD 2.99 price point for this subscription')
        equalizations = self.client.list(f"/v1/subscriptionPricePoints/{base['id']}/equalizations", limit=8000)
        prices = self.client.list(f'/v1/subscriptions/{product_id}/prices', include='territory,subscriptionPricePoint', limit=200)
        by_territory = {}
        for price in prices:
            territory = rel_id(price, 'territory')
            if territory in by_territory:
                raise RuntimeError('Multiple scheduled prices need attention: ' + territory)
            by_territory[territory] = price
        territories = self.client.list('/v1/territories', limit=200)
        expected = {rel_id(p, 'territory'): p['id'] for p in [base, *equalizations]}
        today = datetime.date.today().isoformat()
        for territory in territories:
            identifier = territory['id']
            point = expected.get(identifier)
            if not point:
                raise RuntimeError('Missing Apple equalized price for ' + identifier)
            existing = by_territory.get(identifier)
            if existing:
                if (rel_id(existing, 'subscriptionPricePoint') != point
                        or (existing['attributes'].get('startDate') or today) > today):
                    raise RuntimeError('Existing subscription price differs from confirmed price: ' + identifier)
            else:
                self.create('subscriptionPrices', {'preserveCurrentPrice': True}, {
                    'subscription': relationship('subscriptions', product_id),
                    'subscriptionPricePoint': relationship('subscriptionPricePoints', point)})
        offers = self.client.list(f'/v1/subscriptions/{product_id}/introductoryOffers', include='territory', limit=200)
        today = datetime.date.today().isoformat()
        active = [row for row in offers if not row['attributes'].get('endDate') or row['attributes']['endDate'] >= today]
        offers_by_territory = {}
        for offer in active:
            territory = rel_id(offer, 'territory')
            if territory in offers_by_territory:
                raise RuntimeError('Multiple introductory offers need attention: ' + territory)
            offers_by_territory[territory] = offer
        wanted = {'offerMode': 'FREE_TRIAL', 'duration': 'TWO_WEEKS', 'numberOfPeriods': 1}
        for territory in territories:
            identifier = territory['id']
            existing = offers_by_territory.get(identifier)
            if existing:
                attrs = existing['attributes']
                if any(attrs.get(k) != v for k, v in wanted.items()) or attrs.get('endDate') or (attrs.get('startDate') or today) > today:
                    raise RuntimeError('Existing introductory offer differs from the two-week trial: ' + identifier)
            else:
                self.create('subscriptionIntroductoryOffers', wanted, {
                    'subscription': relationship('subscriptions', product_id),
                    'territory': relationship('territories', identifier)})
        availability = self.client.optional(f'/v1/subscriptions/{product_id}/subscriptionAvailability')
        if not availability:
            self.create('subscriptionAvailabilities', {'availableInNewTerritories': True}, {
                'subscription': relationship('subscriptions', product_id),
                'availableTerritories': {'data': [{'type': 'territories', 'id': t['id']} for t in territories]}})

    def prepare(self, build):
        if not self.release.preflight():
            return {'appStoreVersion': self.release.current(), 'submitted': True}
        version = self.release.current()
        first = not any(state(v) in {'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION'} for v in self.release.versions())
        if not version:
            version = self.create('appStoreVersions', {'platform': 'IOS', 'versionString': self.release.metadata['version'],
                'releaseType': 'AFTER_APPROVAL', 'copyright': '2026 Fenjin Wang'},
                {'app': relationship('apps', self.release.app)})
        ready = state(version) == 'READY_FOR_REVIEW'
        if state(version) not in EDITABLE | {'READY_FOR_REVIEW'}:
            raise RuntimeError('iPad version must be editable before preparing storefront metadata')
        if ready:
            attached = self.client.request('GET', f"/v1/appStoreVersions/{version['id']}/relationships/build").get('data')
            if not attached or attached['id'] != build['id']:
                raise RuntimeError('Ready-for-review iPad draft uses a different build')
        self.app_information()
        localizations = self.client.list(f"/v1/appStoreVersions/{version['id']}/appStoreVersionLocalizations", limit=200)
        by_locale = {row['attributes']['locale']: row for row in localizations}
        for locale, fields in self.release.metadata['localizations'].items():
            attrs = {'description': fields['description'], 'keywords': fields['keywords'],
                     'promotionalText': fields['promotional_text'], 'supportUrl': self.store['support_url'],
                     'marketingUrl': 'https://github.com/tehrandavis/prose'}
            if not first:
                attrs['whatsNew'] = fields['whats_new']
            row = by_locale.get(locale)
            if row:
                if ready:
                    if any(row['attributes'].get(k) != v for k, v in attrs.items()):
                        raise RuntimeError('Ready-for-review iPad metadata differs from source')
                else:
                    self.client.patch('appStoreVersionLocalizations', row['id'], attrs)
            else:
                if ready:
                    raise RuntimeError('Ready-for-review iPad draft is missing a locale')
                row = self.create('appStoreVersionLocalizations', {'locale': locale, **attrs},
                                  {'appStoreVersion': relationship('appStoreVersions', version['id'])})
            sets = self.client.list(f"/v1/appStoreVersionLocalizations/{row['id']}/appScreenshotSets", limit=200)
            screenshot_set = unique([s for s in sets if s['attributes']['screenshotDisplayType'] == 'APP_IPAD_PRO_3GEN_129'], '13-inch screenshot set')
            if not screenshot_set:
                if ready:
                    raise RuntimeError('Ready-for-review iPad draft is missing its screenshot set')
                screenshot_set = self.create('appScreenshotSets', {'screenshotDisplayType': 'APP_IPAD_PRO_3GEN_129'},
                    {'appStoreVersionLocalization': relationship('appStoreVersionLocalizations', row['id'])})
            screenshots = self.client.list(f"/v1/appScreenshotSets/{screenshot_set['id']}/appScreenshots", limit=200)
            for filename in self.store['screenshots'][locale]:
                self.upload_asset('appScreenshots', ROOT / 'iPad/Storefront/screenshots' / filename,
                                  {'appScreenshotSet': relationship('appScreenshotSets', screenshot_set['id'])}, screenshots,
                                  editable=not ready)
        details = self.client.optional(f"/v1/appStoreVersions/{version['id']}/appStoreReviewDetail")
        if not details:
            if ready:
                raise RuntimeError('Ready-for-review iPad draft is missing its review contact')
            macs = self.client.list(f'/v1/apps/{self.release.app}/appStoreVersions', **{'filter[platform]': 'MAC_OS', 'limit': 200})
            macs.sort(key=lambda v: v['attributes'].get('createdDate', ''), reverse=True)
            source = next(iter(macs), None)
            inherited = self.client.optional(f"/v1/appStoreVersions/{source['id']}/appStoreReviewDetail") if source else None
            if not inherited or not all(inherited['attributes'].get(k) for k in
                    ('contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail')):
                raise RuntimeError('Set App Review contact information on the iPad draft first')
            attrs = {k: inherited['attributes'][k] for k in
                     ('contactFirstName', 'contactLastName', 'contactPhone', 'contactEmail')}
            self.create('appStoreReviewDetails', {**attrs, 'demoAccountRequired': False, 'notes': REVIEW_NOTES},
                        {'appStoreVersion': relationship('appStoreVersions', version['id'])})
        elif not ready:
            self.client.patch('appStoreReviewDetails', details['id'], {'demoAccountRequired': False, 'notes': REVIEW_NOTES})
        elif details['attributes'].get('demoAccountRequired') or details['attributes'].get('notes') != REVIEW_NOTES:
            raise RuntimeError('Ready-for-review iPad review information differs from source')
        product, subscription_version, group_version, approved = self.subscription()
        if not ready:
            self.client.request('PATCH', f"/v1/appStoreVersions/{version['id']}/relationships/build", relationship('builds', build['id']))
            self.client.patch('appStoreVersions', version['id'], {'releaseType': 'AFTER_APPROVAL'})
        return {'appStoreVersion': version, 'subscription': product, 'subscriptionVersion': subscription_version,
                'subscriptionGroupVersion': group_version, 'firstSubscription': not approved,
                'submitted': False, 'appStoreConnectUrl': f'https://appstoreconnect.apple.com/apps/{self.release.app}/distribution/ios/version/inflight'}

    def app_information(self):
        # App Info and download pricing are shared with Mac. Preserve existing
        # localized names/categories/privacy answers and require the free price.
        infos = self.client.list(f'/v1/apps/{self.release.app}/appInfos', limit=200)
        info = unique([i for i in infos if state(i) in EDITABLE], 'editable app information')
        if not info:
            info = unique([i for i in infos if state(i) in {'READY_FOR_SALE', 'READY_FOR_DISTRIBUTION'}],
                          'published app information')
        if not info:
            info = unique([i for i in infos if state(i) in {'READY_FOR_REVIEW', 'WAITING_FOR_REVIEW',
                          'IN_REVIEW', 'ACCEPTED', 'PENDING_RELEASE'}], 'shared app information in review')
        if not info:
            raise RuntimeError('App information and age rating must be configured in App Store Connect')
        locales = self.client.list(f"/v1/appInfos/{info['id']}/appInfoLocalizations", limit=200)
        by_locale = {row['attributes']['locale']: row for row in locales}
        for locale, fields in self.release.metadata['localizations'].items():
            privacy_url = self.store['privacy_urls'][locale]
            row = by_locale.get(locale)
            if not row:
                if state(info) not in EDITABLE:
                    raise RuntimeError('Missing shared App Info locale: ' + locale)
                self.create('appInfoLocalizations', {'locale': locale, 'name': fields['name'],
                    'subtitle': fields['subtitle'], 'privacyPolicyUrl': privacy_url},
                    {'appInfo': relationship('appInfos', info['id'])})
            elif row['attributes'].get('privacyPolicyUrl') != privacy_url:
                raise RuntimeError('Shared privacy URL differs from the iPad policy; reconcile it first')
        schedule = self.client.optional(f'/v1/apps/{self.release.app}/appPriceSchedule')
        if not schedule:
            raise RuntimeError('The free app download price is not configured')
        prices = self.client.list(f"/v1/appPriceSchedules/{schedule['id']}/manualPrices",
                                  **{'filter[territory]': 'USA', 'include': 'appPricePoint', 'limit': 200})
        if not prices:
            prices = self.client.list(f"/v1/appPriceSchedules/{schedule['id']}/automaticPrices",
                                      **{'filter[territory]': 'USA', 'include': 'appPricePoint', 'limit': 200})
        today = datetime.date.today().isoformat()
        active = [p for p in prices if (p['attributes'].get('startDate') or today) <= today
                  and (p['attributes'].get('endDate') or '9999-12-31') > today]
        price = unique(active, 'current free download price')
        if not price:
            raise RuntimeError('The USA app download price is missing')
        point_id = rel_id(price, 'appPricePoint')
        if not point_id:
            raise RuntimeError('Apple did not return the USA app price point; cannot verify the free download price')
        point = self.client.request('GET', f'/v3/appPricePoints/{point_id}')['data']
        if Decimal(point['attributes']['customerPrice']) != 0:
            raise RuntimeError('Prose must remain a free download on both platforms')

    def submit(self, build):
        prepared = self.prepare(build)
        if prepared['submitted']:
            return prepared
        if prepared['firstSubscription']:
            destination = ROOT / 'build/iPad-release/review-prepared.json'
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_text(json.dumps(prepared, indent=2) + '\n')
            raise RuntimeError('First subscription is prepared. Apple requires its initial submission with the iPad binary through App Store Connect; subsequent tags submit automatically.')
        version = prepared['appStoreVersion']
        expected = {('appStoreVersion', 'appStoreVersions', version['id'])}
        for name, kind in [('subscriptionVersion', 'subscriptionVersions'), ('subscriptionGroupVersion', 'subscriptionGroupVersions')]:
            if prepared[name]:
                expected.add((name, kind, prepared[name]['id']))
        drafts = []
        for submission in self.client.list(f'/v1/apps/{self.release.app}/reviewSubmissions', **{'filter[platform]': 'IOS', 'limit': 200}):
            if submission['attributes']['state'] == 'COMPLETE':
                continue
            items = self.client.list(f"/v1/reviewSubmissions/{submission['id']}/items", limit=200)
            items = [i for i in items if i.get('attributes', {}).get('state') != 'REMOVED']
            actual = {(name, kind, rel_id(i, name)) for i in items for name, kind, _ in expected if rel_id(i, name)}
            unrelated = any(not any(rel_id(item, name) == identifier for name, _, identifier in expected)
                            for item in items if item.get('attributes', {}).get('state') != 'REMOVED')
            if submission['attributes']['state'] != 'READY_FOR_REVIEW' or unrelated or not actual <= expected:
                raise RuntimeError('An unrelated or unresolved iOS review submission exists')
            drafts.append((submission, actual))
        draft = unique(drafts, 'iOS review draft')
        if draft:
            submission, actual = draft
        else:
            submission = self.create('reviewSubmissions', {'platform': 'IOS'}, {'app': relationship('apps', self.release.app)})
            actual = set()
        for name, kind, identifier in sorted(expected - actual):
            self.create('reviewSubmissionItems', rels={'reviewSubmission': relationship('reviewSubmissions', submission['id']),
                                                     name: relationship(kind, identifier)})
        self.client.patch('reviewSubmissions', submission['id'], {'submitted': True})
        deadline = time.monotonic() + 120
        while True:
            result = self.client.request('GET', f"/v1/reviewSubmissions/{submission['id']}")['data']
            if result['attributes']['state'] in {'WAITING_FOR_REVIEW', 'IN_REVIEW', 'COMPLETE', 'COMPLETING'}:
                return result
            if time.monotonic() >= deadline:
                raise RuntimeError('iPad submission state not confirmed; rerun to discover the actual outcome')
            time.sleep(10)
