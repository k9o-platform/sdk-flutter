import 'dart:convert';

import 'package:test/test.dart';

import 'helpers.dart';

const base = 'https://acme.api.k9o.io/@member-portal/storage/buckets';

const bucketJson = {
  'name': 'avatars',
  'public': false,
  'fileSizeLimit': 1048576,
  'allowedMimeTypes': ['image/png'],
  'versioning': false,
  'deleteAfterDays': null,
  'createdAt': '2026-10-26T10:00:00.000Z',
  'updatedAt': '2026-10-26T10:00:00.000Z',
  'system': false,
  'byosBindingId': null,
};

void main() {
  group('buckets', () {
    test('listBuckets GETs /storage/buckets and decodes', () async {
      final cap = Cap();
      final r = await mk(cap, data: [bucketJson]).storage.listBuckets();
      expect(cap.req.method, 'GET');
      expect(cap.req.url.toString(), base);
      expect(r.data.single.name, 'avatars');
      expect(r.data.single.fileSizeLimit, 1048576);
      expect(r.data.single.allowedMimeTypes, ['image/png']);
      expect(r.data.single.byosBindingId, isNull);
    });

    test('getBucket encodes the name', () async {
      final cap = Cap();
      await mk(cap, data: bucketJson).storage.getBucket('my bucket');
      expect(cap.req.url.toString(), '$base/my%20bucket');
    });

    test('createBucket sends only the options given', () async {
      final cap = Cap();
      await mk(cap, data: bucketJson).storage.createBucket(
        'avatars',
        fileSizeLimit: 10,
        allowedMimeTypes: ['image/png'],
      );
      expect(cap.req.method, 'POST');
      expect(cap.req.url.toString(), base);
      expect(cap.json, {
        'name': 'avatars',
        'fileSizeLimit': 10,
        'allowedMimeTypes': ['image/png'],
      });
    });

    test('updateBucket PATCHes; clear sets fields to null', () async {
      final cap = Cap();
      await mk(cap, data: bucketJson).storage.updateBucket(
        'avatars',
        public: true,
        clear: {'fileSizeLimit', 'allowedMimeTypes'},
      );
      expect(cap.req.method, 'PATCH');
      expect(cap.req.url.toString(), '$base/avatars');
      expect(cap.json, {
        'public': true,
        'fileSizeLimit': null,
        'allowedMimeTypes': null,
      });
    });

    test('updateBucket refuses an unknown clear field', () async {
      final cap = Cap();
      final e = await kerrorOf(
        () => mk(cap).storage.updateBucket('avatars', clear: {'name'}),
      );
      expect(e.code, 'K9O_INVALID_FIELD_VALUE');
      expect(cap.count, 0);
    });

    test('deleteBucket sends empty=true only when asked', () async {
      final cap = Cap();
      final core = mk(
        cap,
        data: {'name': 'avatars', 'deleted': true, 'objectsDeleted': 3},
      );
      await core.storage.deleteBucket('avatars');
      expect(cap.req.method, 'DELETE');
      expect(cap.req.url.toString(), '$base/avatars');
      final r = await core.storage.deleteBucket('avatars', empty: true);
      expect(cap.req.url.toString(), '$base/avatars?empty=true');
      expect(r.data.objectsDeleted, 3);
    });

    test(
      'empty and dot-segment bucket names are refused before any request',
      () async {
        final cap = Cap(), core = mk(cap);
        for (final n in ['', '.', '..']) {
          expect(
            (await kerrorOf(() => core.storage.getBucket(n))).code,
            'K9O_INVALID_FIELD_VALUE',
          );
        }
        expect(
          (await kerrorOf(() => core.storage.from('..').list())).code,
          'K9O_INVALID_FIELD_VALUE',
        );
        expect(cap.count, 0);
      },
    );

    test('a missing slug is refused', () async {
      final cap = Cap();
      expect(
        (await kerrorOf(() => mk(cap, slug: null).storage.listBuckets())).code,
        'K9O_MISSING_PROJECT_CONTEXT',
      );
      expect(cap.count, 0);
    });
  });

  group('objects', () {
    test(
      'upload sends multipart with path, upsert, contentType and metadata',
      () async {
        final cap = Cap();
        final r =
            await mk(
                  cap,
                  data: {'path': 'a/b.txt', 'size': 5, 'lastModified': null},
                  status: 201,
                ).storage
                .from('avatars')
                .upload(
                  'a/b.txt',
                  utf8.encode('hello'),
                  contentType: 'text/plain',
                  upsert: true,
                  metadata: {'k': 'v'},
                );
        expect(cap.req.method, 'POST');
        expect(cap.req.url.toString(), '$base/avatars/objects');
        expect(
          cap.req.headers['content-type'],
          startsWith('multipart/form-data; boundary='),
        );
        final text = cap.bodyText;
        expect(text, contains('name="path"'));
        expect(text, contains('a/b.txt'));
        expect(text, contains('name="upsert"\r\n\r\ntrue'));
        expect(text, contains('name="contentType"\r\n\r\ntext/plain'));
        expect(text, contains('name="metadata"\r\n\r\n{"k":"v"}'));
        expect(text, contains('name="file"; filename="b.txt"'));
        expect(text, contains('hello'));
        expect(r.data.path, 'a/b.txt');
        expect(r.data.size, 5);
      },
    );

    test('upload defaults to upsert=false and omits contentType', () async {
      final cap = Cap();
      await mk(
        cap,
        data: {'path': 'x', 'size': 1, 'lastModified': null},
      ).storage.from('avatars').uploadText('x', 'y');
      expect(cap.bodyText, contains('name="upsert"\r\n\r\nfalse'));
      expect(cap.bodyText, contains('name="contentType"\r\n\r\ntext/plain'));
      await mk(
        cap,
        data: {'path': 'x', 'size': 1, 'lastModified': null},
      ).storage.from('avatars').upload('x', [1, 2]);
      expect(cap.bodyText, isNot(contains('name="contentType"')));
    });

    test('createSignedUrl posts path and expiresIn', () async {
      final cap = Cap();
      final r =
          await mk(cap, data: {'signedUrl': 'https://x/y', 'expiresIn': 900})
              .storage
              .from('avatars')
              .createSignedUrl('a.png', expiresIn: 3600, download: true);
      expect(cap.req.method, 'POST');
      expect(cap.req.url.toString(), '$base/avatars/objects/sign');
      expect(cap.json, {'path': 'a.png', 'expiresIn': 3600, 'download': true});
      expect(r.data.expiresIn, 900);
      expect(r.data.signedUrl, 'https://x/y');
    });

    test('expiresIn outside 1..604800 and empty paths are refused before any request', () async {
      final cap = Cap(), h = mk(cap).storage.from('avatars');
      expect(
        (await kerrorOf(() => h.createSignedUrl('a', expiresIn: 0))).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(() => h.createSignedUrl('a', expiresIn: 604801))).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(() => h.createSignedUrl('', expiresIn: 5))).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(() => h.upload('', [1]))).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(
        (await kerrorOf(() => h.remove(''))).code,
        'K9O_INVALID_FIELD_VALUE',
      );
      expect(cap.count, 0);
      await mk(
        cap,
        data: {'signedUrl': 'u', 'expiresIn': 1},
      ).storage.from('avatars').createSignedUrl('a', expiresIn: 604800);
      expect(cap.count, 1);
    });

    test('list GETs /objects with an optional prefix', () async {
      final cap = Cap();
      final core = mk(
        cap,
        data: [
          {
            'path': 'a/1.txt',
            'size': 3,
            'lastModified': '2026-10-26T10:00:00.000Z',
          },
        ],
      );
      final r = await core.storage.from('avatars').list();
      expect(cap.req.url.toString(), '$base/avatars/objects');
      expect(r.data.single.lastModified, '2026-10-26T10:00:00.000Z');
      await core.storage.from('avatars').list(prefix: 'a/');
      expect(cap.req.url.toString(), '$base/avatars/objects?prefix=a%2F');
    });

    test('remove DELETEs /objects?path=', () async {
      final cap = Cap();
      final r = await mk(
        cap,
        data: {'bucket': 'avatars', 'path': 'a/1.txt', 'deleted': true},
      ).storage.from('avatars').remove('a/1.txt');
      expect(cap.req.method, 'DELETE');
      expect(cap.req.url.toString(), '$base/avatars/objects?path=a%2F1.txt');
      expect(r.data.deleted, isTrue);
    });

    test('gateway errors surface as KError', () async {
      final cap = Cap();
      final core = mk(
        cap,
        status: 409,
        errorBody: {'code': 'K9O_ALREADY_EXISTS', 'message': 'exists'},
      );
      final e = await kerrorOf(
        () => core.storage.from('avatars').upload('a', [1]),
      );
      expect(e.code, 'K9O_ALREADY_EXISTS');
      expect(e.status, 409);
    });
  });
}
