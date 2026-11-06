// Port of eino-ext `components/tool/googlesearch/google_search_test.go`
// (TestGooGleSearchTool, case query_success).
//
// Go patches `customsearch.CseListCall.Do` (mockey) to return the decoded
// fixture. Here a `MockClient` answers the request the tool sends with the
// same fixture, byte for byte as the Custom Search JSON API sends it (its
// `<`-style escapes are kept: the fixture writes them with `@u`, turned
// into a backslash and `u` before use). Go's mock key and engine ID are
// replaced by `test-key` and `test-cx`.
//
// Everything after the ported group is written for the port: the request
// on the wire (path, sorted query parameters, `User-Agent`), the exact bytes
// of the answer to the model, the error answers of the API (Go's
// `googleapi.Error` texts, derived from `googleapi.go`), malformed answers,
// meta-tag descriptions, the typed `searchResults`, cancellation, timeouts
// and client ownership.
//
// Deliberate deviations pinned here (see the `GoogleSearchTool` dartdoc): a
// hit without `pagemap` has no description (Go fails the whole call), an
// answer without `queries` or a 204 is tolerated (Go panics), and the API
// key never shows in errors (Go's `url.Error` quotes it).
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/tool/google_search/google_search_tool.dart';
import 'package:threepio_core/src/components/tool/search_result.dart';
import 'package:threepio_core/threepio_core.dart';

final _backslash = String.fromCharCode(92);

/// The fixture of the Go test (`mockSearchResult`), escapes restored.
final _mockSearchResult = r'''
{
    "context": {
      "title": "EinoSearchTool"
    },
    "items": [
      {
        "displayLink": "www.cnblogs.com",
        "formattedUrl": "https://www.cnblogs.com/xueqiuqiu/articles/12955291.html",
        "htmlFormattedUrl": "https://www.cnblogs.com/xueqiuqiu/articles/12955291.html",
        "htmlSnippet": "May 25, 2020 @u003cb@u003e...@u003c/b@u003e @u003cb@u003ePregel@u003c/b@u003e 使用@u003cb@u003e两种@u003c/b@u003e方法来实现容错性: Checkpoint 在Superstep 执行前进行，用来保存当前系统的状态。当某一图分区计算失败但Worker 仍然可用时，@u0026nbsp;...",
        "htmlTitle": "图解图算法@u003cb@u003ePregel@u003c/b@u003e: 模型简介与实战案例- 雪球球- 博客园",
        "kind": "customsearch#result",
        "link": "https://www.cnblogs.com/xueqiuqiu/articles/12955291.html",
        "pagemap": {
          "metatags": [
            {
              "referrer": "never",
              "og:image": "https://io-meter.com/img/pregel/pregel-basic-model.png",
              "viewport": "width=device-width, initial-scale=1.0",
              "og:description": "这篇文章是对之前在@u0026#160;SHLUG@u0026#160;月度分享活动上所作演讲@u0026#160;Pregel in Graphs@u0026#160;的总结。为使分享内容清晰易懂，本人绘制了大量原创示意图，这篇文字版的总结也会尽量以这些图示为主。 除了对 Pregel 算法的简单介绍，本文还附加了一个用户追踪画像的实战"
            }
          ],
          "cse_image": [
            {
              "src": "https://io-meter.com/img/pregel/pregel-basic-model.png"
            }
          ]
        },
        "snippet": "May 25, 2020 ... Pregel 使用两种方法来实现容错性: Checkpoint 在Superstep 执行前进行，用来保存当前系统的状态。当某一图分区计算失败但Worker 仍然可用时， ...",
        "title": "图解图算法Pregel: 模型简介与实战案例- 雪球球- 博客园"
      },
      {
        "displayLink": "fuhailin.github.io",
        "formattedUrl": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/",
        "htmlFormattedUrl": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/",
        "htmlSnippet": "Apr 29, 2019 @u003cb@u003e...@u003c/b@u003e 虽然，类似@u003cb@u003ePregel@u003c/b@u003e等图计算框架也是将结果保存在内存当中，但是，这些框架只能支持一些特定的计算@u003cb@u003e模式@u003c/b@u003e，并没有提供一种通用的数据抽象。RDD就是为了满足这种@u0026nbsp;...",
        "htmlTitle": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版) | 赵大寳",
        "kind": "customsearch#result",
        "link": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/",
        "pagemap": {
          "person": [
            {
              "image": "https://gitee.com/fuhailin/Object-Storage-Service/raw/master/uploads-avatar.jpg",
              "name": "赵大寳",
              "description": "赵大寳個人小站"
            },
            {
              "image": "https://gitee.com/fuhailin/Object-Storage-Service/raw/master/uploads-avatar.jpg",
              "name": "赵大寳",
              "description": "赵大寳個人小站"
            }
          ],
          "organization": [
            {
              "name": "赵大寳"
            }
          ],
          "metatags": [
            {
              "og:image": "https://gitee.com/fuhailin/Object-Storage-Service/raw/master/Spark-Action-Transformation.jpg",
              "theme-color": "#222",
              "og:type": "article",
              "article:published_time": "2019-04-29T06:56:00.000Z",
              "twitter:card": "summary",
              "og:site_name": "赵大寳",
              "og:title": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版)",
              "og:description": "IntroductionRDD（Resilient Distributed Dataset）叫做弹性分布式数据集，在之前的Spark基本概念当中我已经介绍过RDD是Spark中最基本的数据结构，是一个不可变的分布式对象集合。Spark的核心是建立在统一的抽象RDD之上，使得Spark的各个组件可以无缝进行集成，在同一个应用程序中完成大数据计算任务。RDD的设计理念源自AMP实验室发表的论文《Res",
              "article:author": "赵大寳",
              "twitter:image": "https://gitee.com/fuhailin/Object-Storage-Service/raw/master/Spark-Action-Transformation.jpg",
              "article:tag": "Python",
              "article:modified_time": "2021-07-23T06:42:04.641Z",
              "viewport": "width=device-width",
              "og:locale": "en_US",
              "og:url": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/index.html"
            }
          ],
          "webpage": [
            {
              "copyrightholder": "赵大寳",
              "copyrightyear": "2021"
            }
          ],
          "cse_image": [
            {
              "src": "https://gitee.com/fuhailin/Object-Storage-Service/raw/master/Spark-Action-Transformation.jpg"
            }
          ],
          "wpheader": [
            {
              "description": "鶸鸡程序员，新世纪农民工"
            }
          ],
          "thing": [
            {
              "name": "大数据",
              "url": "大数据"
            }
          ],
          "article": [
            {
              "articlebody": "IntroductionRDD（Resilient Distributed Dataset）叫做弹性分布式数据集， 在之前的Spark基本概念当中我已经介绍过RDD是Spark中最基本的数据结构，是一个不可变...",
              "datemodified": "2021-07-23T14:42:04+08:00",
              "name": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版)",
              "datecreated": "2019-04-29T14:56:00+08:00",
              "headline": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版)",
              "datepublished": "2019-04-29T14:56:00+08:00",
              "mainentityofpage": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/"
            }
          ]
        },
        "snippet": "Apr 29, 2019 ... 虽然，类似Pregel等图计算框架也是将结果保存在内存当中，但是，这些框架只能支持一些特定的计算模式，并没有提供一种通用的数据抽象。RDD就是为了满足这种 ...",
        "title": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版) | 赵大寳"
      },
      {
        "displayLink": "www.cnblogs.com",
        "formattedUrl": "https://www.cnblogs.com/linhaifeng/p/15919143.html",
        "htmlFormattedUrl": "https://www.cnblogs.com/linhaifeng/p/15919143.html",
        "htmlSnippet": "Feb 21, 2022 @u003cb@u003e...@u003c/b@u003e 一Spark与hadoop Hadoop有两个核心模块，分布式存储模块HDFS和分布式计算模块Mapreduce Spark 支持多种编程语言，包括Java、Python、R 和Scala，@u0026nbsp;...",
        "htmlTitle": "Spark@u003cb@u003e运行@u003c/b@u003e架构- linhaifeng - 博客园",
        "kind": "customsearch#result",
        "link": "https://www.cnblogs.com/linhaifeng/p/15919143.html",
        "pagemap": {
          "metatags": [
            {
              "referrer": "origin-when-cross-origin",
              "og:image": "https://img2022.cnblogs.com/blog/1036857/202202/1036857-20220221153424091-878075794.png",
              "viewport": "width=device-width, initial-scale=1.0",
              "og:description": "一 Spark与hadoop Hadoop有两个核心模块，分布式存储模块HDFS和分布式计算模块Mapreduce Spark 支持多种编程语言，包括 Java、Python、R 和 Scala，同时 Spark 也支持 Hadoop 的底层存储系统 HDFS，但 Spark 不依赖 Hadoop。"
            }
          ],
          "cse_image": [
            {
              "src": "https://img2022.cnblogs.com/blog/1036857/202202/1036857-20220221153424091-878075794.png"
            }
          ]
        },
        "snippet": "Feb 21, 2022 ... 一Spark与hadoop Hadoop有两个核心模块，分布式存储模块HDFS和分布式计算模块Mapreduce Spark 支持多种编程语言，包括Java、Python、R 和Scala， ...",
        "title": "Spark运行架构- linhaifeng - 博客园"
      }
    ],
    "kind": "customsearch#search",
    "queries": {
      "nextPage": [
        {
          "count": 3,
          "cx": "b7154871356604f48",
          "gl": "zh-CN",
          "inputEncoding": "utf8",
          "outputEncoding": "utf8",
          "safe": "off",
          "searchTerms": "Pregel 和 DAG 两种图运行模式的区别",
          "startIndex": 4,
          "title": "Google Custom Search - Pregel 和 DAG 两种图运行模式的区别",
          "totalResults": "1850"
        }
      ],
      "request": [
        {
          "count": 3,
          "cx": "b7154871356604f48",
          "gl": "zh-CN",
          "inputEncoding": "utf8",
          "outputEncoding": "utf8",
          "safe": "off",
          "searchTerms": "Pregel 和 DAG 两种图运行模式的区别",
          "startIndex": 1,
          "title": "Google Custom Search - Pregel 和 DAG 两种图运行模式的区别",
          "totalResults": "1850"
        }
      ]
    },
    "searchInformation": {
      "formattedSearchTime": "0.42",
      "formattedTotalResults": "1,850",
      "searchTime": 0.42296,
      "totalResults": "1850"
    },
    "url": {
      "template": "https://www.googleapis.com/customsearch/v1?q={searchTerms}@u0026num={count?}@u0026start={startIndex?}@u0026lr={language?}@u0026safe={safe?}@u0026cx={cx?}@u0026sort={sort?}@u0026filter={filter?}@u0026gl={gl?}@u0026cr={cr?}@u0026googlehost={googleHost?}@u0026c2coff={disableCnTwTranslation?}@u0026hq={hq?}@u0026hl={hl?}@u0026siteSearch={siteSearch?}@u0026siteSearchFilter={siteSearchFilter?}@u0026exactTerms={exactTerms?}@u0026excludeTerms={excludeTerms?}@u0026linkSite={linkSite?}@u0026orTerms={orTerms?}@u0026dateRestrict={dateRestrict?}@u0026lowRange={lowRange?}@u0026highRange={highRange?}@u0026searchType={searchType}@u0026fileType={fileType?}@u0026rights={rights?}@u0026imgSize={imgSize?}@u0026imgType={imgType?}@u0026imgColorType={imgColorType?}@u0026imgDominantColor={imgDominantColor?}@u0026alt=json",
      "type": "application/json"
    }
  }
'''
    .replaceAll('@u', '${_backslash}u');

/// The expected tool output of the Go test (`expectedToolOutput`).
const _expectedToolOutput = r'''
{
	"query": "Pregel 和 DAG 两种图运行模式的区别",
	"items": [
	  {
		  "snippet": "May 25, 2020 ... Pregel 使用两种方法来实现容错性: Checkpoint 在Superstep 执行前进行，用来保存当前系统的状态。当某一图分区计算失败但Worker 仍然可用时， ...",
		  "desc": "这篇文章是对之前在&#160;SHLUG&#160;月度分享活动上所作演讲&#160;Pregel in Graphs&#160;的总结。为使分享内容清晰易懂，本人绘制了大量原创示意图，这篇文字版的总结也会尽量以这些图示为主。 除了对 Pregel 算法的简单介绍，本文还附加了一个用户追踪画像的实战",
		  "link": "https://www.cnblogs.com/xueqiuqiu/articles/12955291.html",
		  "title": "图解图算法Pregel: 模型简介与实战案例- 雪球球- 博客园"
	  },
	  {
		  "snippet": "Apr 29, 2019 ... 虽然，类似Pregel等图计算框架也是将结果保存在内存当中，但是，这些框架只能支持一些特定的计算模式，并没有提供一种通用的数据抽象。RDD就是为了满足这种 ...",
		  "desc": "IntroductionRDD（Resilient Distributed Dataset）叫做弹性分布式数据集，在之前的Spark基本概念当中我已经介绍过RDD是Spark中最基本的数据结构，是一个不可变的分布式对象集合。Spark的核心是建立在统一的抽象RDD之上，使得Spark的各个组件可以无缝进行集成，在同一个应用程序中完成大数据计算任务。RDD的设计理念源自AMP实验室发表的论文《Res",
		  "link": "https://fuhailin.github.io/Program-with-RDD-in-PySpark/",
		  "title": "Spark入门笔记—编程操作对象RDD与DataFrame(PySpark版) | 赵大寳"
	  },
	  {
		  "link": "https://www.cnblogs.com/linhaifeng/p/15919143.html",
		  "title": "Spark运行架构- linhaifeng - 博客园",
		  "snippet": "Feb 21, 2022 ... 一Spark与hadoop Hadoop有两个核心模块，分布式存储模块HDFS和分布式计算模块Mapreduce Spark 支持多种编程语言，包括Java、Python、R 和Scala， ...",
		  "desc": "一 Spark与hadoop Hadoop有两个核心模块，分布式存储模块HDFS和分布式计算模块Mapreduce Spark 支持多种编程语言，包括 Java、Python、R 和 Scala，同时 Spark 也支持 Hadoop 的底层存储系统 HDFS，但 Spark 不依赖 Hadoop。"
	  }
	]
}
''';

/// The expected schema of the Go test (`expectedSchema`).
const _expectedSchema = {
  'properties': {
    'query': {
      'description': 'queried string to the search engine',
      'type': 'string',
    },
    'num': {
      'description': 'number of search results to return, valid values are '
          'between 1 and 10, inclusive',
      'type': 'integer',
    },
    'offset': {
      'description': 'the index of the first result to return.',
      'type': 'integer',
    },
    'lang': {
      'description': 'sets the user interface language, default english. '
          'usually represented by a 2-4 letter code in ISO 639-1. e.g. en, '
          'ja, zh-CN',
      'type': 'string',
    },
  },
  'additionalProperties': false,
  'required': ['query'],
  'type': 'object',
};

const _mockSearchQuery = 'Pregel 和 DAG 两种图运行模式的区别';

/// [value] without the entries whose value is `null`.
Object? _compact(Object? value) => switch (value) {
      final Map<String, Object?> map => {
          for (final MapEntry(:key, :value) in map.entries)
            if (value != null) key: _compact(value),
        },
      final List<Object?> list => [for (final item in list) _compact(item)],
      _ => value,
    };

TypeMatcher<ThreepioException> _threepio(String message) =>
    isA<ThreepioException>().having((e) => e.message, 'message', message);

TypeMatcher<ThreepioException> _threepioContaining(String part) =>
    isA<ThreepioException>().having((e) => e.message, 'message', contains(part));

/// A search answer with [items] and the search terms [terms].
String _answer(List<Map<String, Object?>> items, {String terms = 'q'}) =>
    jsonEncode({
      'kind': 'customsearch#search',
      'queries': {
        'request': [
          {'searchTerms': terms, 'count': items.length, 'startIndex': 1},
        ],
      },
      'items': items,
    });

/// A tool whose requests are answered by [handler].
GoogleSearchTool _tool(
  Future<http.Response> Function(http.Request request) handler, {
  String? baseUrl,
  int? num,
  String? lang,
  Duration? timeout,
}) =>
    GoogleSearchTool(
      GoogleSearchConfig(
        apiKey: 'test-key',
        searchEngineId: 'test-cx',
        baseUrl: baseUrl,
        num: num,
        lang: lang,
        timeout: timeout,
        httpClient: MockClient(handler),
      ),
    );

/// A client that records whether it was closed.
final class _TrackingClient extends http.BaseClient {
  _TrackingClient(this._inner);

  final http.Client _inner;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() => closed = true;
}

void main() {
  // -------------------------------------------------------------------------
  // google_search_test.go
  // -------------------------------------------------------------------------

  group('TestGooGleSearchTool', () {
    test('query_success', () async {
      final requests = <http.Request>[];
      final tool = GoogleSearchTool(
        GoogleSearchConfig(
          apiKey: 'test-key',
          searchEngineId: 'test-cx',
          num: 3,
          httpClient: MockClient((request) async {
            requests.add(request);
            return http.Response.bytes(
              utf8.encode(_mockSearchResult),
              200,
              headers: {'content-type': 'application/json; charset=UTF-8'},
            );
          }),
        ),
      );

      final info = await tool.info();
      expect(
        _compact(info.paramsOneOf!.toJsonSchema().toJson()),
        _expectedSchema,
      );

      final gsrBody = jsonEncode(
        const GoogleSearchRequest(query: _mockSearchQuery, lang: 'zh-CN')
            .toJson(),
      );
      expect(gsrBody, '{"query":"$_mockSearchQuery","lang":"zh-CN"}');

      final toolOut = await tool.invokableRun(RunContext.background(), gsrBody);
      expect(jsonDecode(toolOut), jsonDecode(_expectedToolOutput));

      // The request: config Num 3, request Lang zh-CN (sent as `gl`).
      expect(requests, hasLength(1));
      expect(requests.single.url.queryParameters, {
        'alt': 'json',
        'cx': 'test-cx',
        'gl': 'zh-CN',
        'key': 'test-key',
        'num': '3',
        'prettyPrint': 'false',
        'q': _mockSearchQuery,
      });
    });
  });

  // -------------------------------------------------------------------------
  // Written for the port.
  // -------------------------------------------------------------------------

  group('answer to the model', () {
    test('byte for byte: Go field order, no HTML escaping', () async {
      final tool = _tool(
        (_) async => http.Response.bytes(utf8.encode(_mockSearchResult), 200),
      );
      final out = await tool.invokableRun(
        RunContext.background(),
        '{"query":"x"}',
      );
      // Go writes SearchResult{query, items} and each item as link, title,
      // snippet, desc: the expected output of the Go test in that order.
      final expected = jsonDecode(_expectedToolOutput) as Map<String, Object?>;
      final ordered = {
        'query': expected['query'],
        'items': [
          for (final item in (expected['items']! as List<Object?>)
              .cast<Map<String, Object?>>())
            {
              'link': item['link'],
              'title': item['title'],
              'snippet': item['snippet'],
              'desc': item['desc'],
            },
        ],
      };
      expect(out, jsonEncode(ordered));
      expect(out, contains('&#160;SHLUG&#160;'));
      expect(out, startsWith('{"query":"$_mockSearchQuery","items":[{"link":'));
    });

    test('empty fields are left out; items is always there', () async {
      final tool = _tool(
        (_) async => http.Response(
          _answer([
            {'link': 'https://a.test/'},
          ], terms: ''),
          200,
        ),
      );
      expect(
        await tool.invokableRun(RunContext.background(), '{"query":""}'),
        '{"items":[{"link":"https://a.test/"}]}',
      );
      final none = _tool((_) async => http.Response(_answer([]), 200));
      expect(
        await none.invokableRun(RunContext.background(), '{"query":"q"}'),
        '{"query":"q","items":[]}',
      );
    });

    test('control characters as sonic writes them (backspace, form feed)',
        () async {
      final tool = _tool(
        (_) async => http.Response(
          _answer([
            {'link': 'l', 'title': 'a\bb\fc\td\ne<f>&g'},
          ]),
          200,
        ),
      );
      final out = await tool.invokableRun(
        RunContext.background(),
        '{"query":"q"}',
      );
      final b = _backslash;
      expect(
        out,
        '{"query":"q","items":[{"link":"l","title":'
        '"a${b}u0008b${b}u000cc${b}td${b}ne<f>&g"}]}',
      );
    });

    test('the search terms of several requests are joined by spaces',
        () async {
      final tool = _tool(
        (_) async => http.Response(
          jsonEncode({
            'queries': {
              'request': [
                {'searchTerms': 'one'},
                {'searchTerms': 'two'},
              ],
            },
            'items': <Object?>[],
          }),
          200,
        ),
      );
      final result = await tool.search(
        RunContext.background(),
        const GoogleSearchRequest(query: 'q'),
      );
      expect(result.query, 'one two');
    });
  });

  group('descriptions from the page map', () {
    Future<List<GoogleSimplifiedSearchItem>> itemsFor(
      List<Map<String, Object?>> items,
    ) async {
      final tool = _tool((_) async => http.Response(_answer(items), 200));
      return (await tool.search(
        RunContext.background(),
        const GoogleSearchRequest(query: 'q'),
      ))
          .items;
    }

    test('description first, else og:description, one line per entry',
        () async {
      final items = await itemsFor([
        {
          'link': 'l',
          'pagemap': {
            'metatags': [
              {'description': 'd1', 'og:description': 'og1'},
              {'og:description': 'og2'},
              {'description': 5, 'og:description': 'og3'},
              'not a map',
              {'other': 'x'},
            ],
          },
        },
      ]);
      expect(items.single.desc, 'd1\nog2\nog3');
    });

    test('no metatags, a null or a missing page map: no description',
        () async {
      final items = await itemsFor([
        {'link': 'a', 'pagemap': {'cse_image': <Object?>[]}},
        {'link': 'b', 'pagemap': {'metatags': 'x'}},
        {'link': 'c', 'pagemap': null},
        {'link': 'd'},
      ]);
      expect([for (final item in items) item.desc], ['', '', '', '']);
    });

    test('a page map that is not an object fails as in Go', () async {
      await expectLater(
        itemsFor([
          {'link': 'a', 'pagemap': <Object?>[1]},
        ]),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'json.Unmarshal Pagemap failed: json: cannot unmarshal array into '
                'Go value of type map[string]interface {}',
          ),
        ),
      );
    });
  });

  group('request', () {
    test('path, sorted Go-escaped query and User-Agent', () async {
      late http.Request seen;
      final tool = _tool((request) async {
        seen = request;
        return http.Response(_answer([]), 200);
      });
      await tool.search(
        RunContext.background(),
        const GoogleSearchRequest(
          query: 'go lang & more/和',
          num: 5,
          offset: 11,
          lang: 'en',
        ),
      );
      expect(seen.method, 'GET');
      expect(
        seen.url.toString(),
        'https://customsearch.googleapis.com/customsearch/v1?alt=json&'
        'cx=test-cx&gl=en&key=test-key&num=5&prettyPrint=false&'
        'q=go+lang+%26+more%2F%E5%92%8C&start=11',
      );
      expect(seen.headers['User-Agent'], 'google-api-go-client/0.5');
    });

    test('num and lang come from the config when the model gives none',
        () async {
      final seen = <Map<String, String>>[];
      final tool = _tool(
        (request) async {
          seen.add(request.url.queryParameters);
          return http.Response(_answer([]), 200);
        },
        num: 4,
        lang: 'ja',
      );
      final ctx = RunContext.background();
      await tool.search(ctx, const GoogleSearchRequest(query: 'q'));
      await tool.search(ctx, const GoogleSearchRequest(query: 'q', num: 7, lang: 'de'));
      await tool.search(ctx, const GoogleSearchRequest(query: 'q', num: -1, offset: -2));
      expect(seen[0], containsPair('num', '4'));
      expect(seen[0], containsPair('gl', 'ja'));
      expect(seen[0].containsKey('start'), isFalse);
      expect(seen[1], containsPair('num', '7'));
      expect(seen[1], containsPair('gl', 'de'));
      expect(seen[2], containsPair('num', '4'));
      expect(seen[2].containsKey('start'), isFalse);
    });

    test('without num and lang anywhere, neither is sent', () async {
      late Map<String, String> seen;
      final tool = _tool((request) async {
        seen = request.url.queryParameters;
        return http.Response(_answer([]), 200);
      });
      await tool.search(
        RunContext.background(),
        const GoogleSearchRequest(query: 'q'),
      );
      expect(seen.keys.toSet(), {'alt', 'cx', 'key', 'prettyPrint', 'q'});
    });

    test('base URLs resolve as the Go client resolves them', () async {
      Future<String> urlFor(String baseUrl) async {
        late Uri seen;
        final tool = _tool(
          (request) async {
            seen = request.url;
            return http.Response(_answer([]), 200);
          },
          baseUrl: baseUrl,
        );
        await tool.search(
          RunContext.background(),
          const GoogleSearchRequest(query: 'q'),
        );
        return seen.replace(query: '').toString().replaceAll('?', '');
      }

      expect(
        await urlFor('http://127.0.0.1:8080/base/'),
        'http://127.0.0.1:8080/base/customsearch/v1',
      );
      expect(
        await urlFor('http://127.0.0.1:8080/base'),
        'http://127.0.0.1:8080/customsearch/v1',
      );
      expect(
        await urlFor('https://customsearch.googleapis.com'),
        'https://customsearch.googleapis.com/customsearch/v1',
      );
      expect(
        await urlFor('proxy.test:9443'),
        'https://proxy.test:9443/customsearch/v1',
      );
    });
  });

  group('configuration', () {
    test('missing api_key or search_engine_id', () {
      for (final config in const [
        GoogleSearchConfig(apiKey: '', searchEngineId: 'cx'),
        GoogleSearchConfig(apiKey: 'test-key', searchEngineId: ''),
      ]) {
        expect(
          () => GoogleSearchTool(config),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              'missing api_key or search_engine_id',
            ),
          ),
        );
      }
    });

    test('a base URL that does not parse', () {
      expect(
        () => GoogleSearchTool(
          const GoogleSearchConfig(
            apiKey: 'test-key',
            searchEngineId: 'cx',
            baseUrl: 'http://[::1',
          ),
        ),
        throwsArgumentError,
      );
    });

    test('defaults and custom names', () async {
      final tool = _tool((_) async => http.Response(_answer([]), 200));
      final info = await tool.info();
      expect(info.name, 'google_search');
      expect(info.desc, 'custom search json api of google search engine');
      expect(tool.componentTypeName, 'GoogleSearch');
      expect(
        info.paramsOneOf!.toJsonSchema().properties.keys,
        ['query', 'num', 'offset', 'lang'],
      );

      final custom = GoogleSearchTool(
        const GoogleSearchConfig(
          apiKey: 'test-key',
          searchEngineId: 'cx',
          toolName: 'web_search',
          toolDesc: 'search the web',
        ),
      );
      addTearDown(custom.dispose);
      expect((await custom.info()).name, 'web_search');
      expect((await custom.info()).desc, 'search the web');
      expect(custom.componentTypeName, 'WebSearch');
    });
  });

  group('error answers', () {
    Future<Object> failure(int status, String body) async {
      final tool = _tool((_) async => http.Response(body, status));
      try {
        await tool.search(
          RunContext.background(),
          const GoogleSearchRequest(query: 'q'),
        );
      } on Object catch (error) {
        return error;
      }
      fail('no error');
    }

    test('an invalid key: message, details and reason as Go', () async {
      const body = '''
{
  "error": {
    "code": 400,
    "message": "API key not valid. Please pass a valid API key.",
    "errors": [
      {
        "message": "API key not valid. Please pass a valid API key.",
        "domain": "global",
        "reason": "badRequest"
      }
    ],
    "status": "INVALID_ARGUMENT",
    "details": [
      {
        "@type": "type.googleapis.com/google.rpc.ErrorInfo",
        "reason": "API_KEY_INVALID",
        "domain": "googleapis.com",
        "metadata": {
          "service": "customsearch.googleapis.com"
        }
      }
    ]
  }
}
''';
      final error = await failure(400, body);
      expect(
        error,
        _threepio(
          'search.cse.list failed: googleapi: Error 400: API key not valid. '
          'Please pass a valid API key.\n'
          'Details:\n'
          '[\n'
          '  {\n'
          '    "@type": "type.googleapis.com/google.rpc.ErrorInfo",\n'
          '    "domain": "googleapis.com",\n'
          '    "metadata": {\n'
          '      "service": "customsearch.googleapis.com"\n'
          '    },\n'
          '    "reason": "API_KEY_INVALID"\n'
          '  }\n'
          ']\n'
          ', badRequest',
        ),
      );
      final cause = (error as ThreepioException).cause! as GoogleApiException;
      expect(cause.code, 400);
      expect(cause.apiMessage, 'API key not valid. Please pass a valid API key.');
      expect(cause.errors, [
        const GoogleApiErrorItem(
          reason: 'badRequest',
          message: 'API key not valid. Please pass a valid API key.',
        ),
      ]);
      expect(cause.details, hasLength(1));
      expect(cause.body, body);
    });

    test('one error whose message matches: ", reason"', () async {
      expect(
        await failure(
          403,
          '{"error":{"code":403,"message":"The caller does not have '
          'permission","errors":[{"message":"The caller does not have '
          'permission","domain":"global","reason":"forbidden"}],'
          '"status":"PERMISSION_DENIED"}}',
        ),
        _threepio(
          'search.cse.list failed: googleapi: Error 403: The caller does not '
          'have permission, forbidden',
        ),
      );
    });

    test('several errors: "More details"', () async {
      expect(
        await failure(
          429,
          '{"error":{"message":"Quota","errors":[{"reason":"r1","message":"m1"},'
          '{"reason":"r2","message":"m2"}]}}',
        ),
        _threepio(
          'search.cse.list failed: googleapi: Error 429: Quota\n'
          'More details:\n'
          'Reason: r1, Message: m1\n'
          'Reason: r2, Message: m2\n',
        ),
      );
    });

    test('a message without errors is trimmed; HTML in details is escaped',
        () async {
      expect(
        await failure(503, '{"error":{"code":503,"message":"Backend Error "}}'),
        _threepio('search.cse.list failed: googleapi: Error 503: Backend Error'),
      );
      final b = _backslash;
      expect(
        await failure(
          400,
          '{"error":{"message":"m","details":[{"z":1.0,"a":"<&>"}]}}',
        ),
        _threepio(
          'search.cse.list failed: googleapi: Error 400: m\nDetails:\n[\n'
          '  {\n    "a": "${b}u003c${b}u0026${b}u003e",\n    "z": 1\n  }\n]',
        ),
      );
    });

    test('a body that is not an error object', () async {
      expect(
        await failure(500, 'oops'),
        _threepio(
          'search.cse.list failed: googleapi: got HTTP response code 500 with '
          'body: oops',
        ),
      );
      expect(
        await failure(502, '{"error":{"code":"bad"}}'),
        _threepio(
          'search.cse.list failed: googleapi: got HTTP response code 502 with '
          'body: {"error":{"code":"bad"}}',
        ),
      );
    });

    test('304 has no body; 204 is an empty result', () async {
      expect(
        await failure(304, 'ignored'),
        _threepio(
          'search.cse.list failed: googleapi: got HTTP response code 304 with '
          'body: ',
        ),
      );
      final tool = _tool((_) async => http.Response('', 204));
      expect(
        await tool.invokableRun(RunContext.background(), '{"query":"q"}'),
        '{"items":[]}',
      );
    });
  });

  group('malformed answers', () {
    Future<void> expectFailure(String body, Matcher matcher) async {
      final tool = _tool((_) async => http.Response(body, 200));
      await expectLater(
        tool.search(
          RunContext.background(),
          const GoogleSearchRequest(query: 'q'),
        ),
        throwsA(matcher),
      );
    }

    test('not JSON', () async {
      await expectFailure(
        '{"items": [',
        isA<ThreepioFormatException>().having(
          (e) => e.message,
          'message',
          startsWith('search.cse.list failed: '),
        ),
      );
    });

    test('fields of the wrong type, with the encoding/json text', () async {
      await expectFailure(
        '{"items":[{"link":5}]}',
        _threepio(
          'search.cse.list failed: json: cannot unmarshal number into Go '
          'struct field Result.items.link of type string',
        ),
      );
      await expectFailure(
        '{"items":{}}',
        _threepioContaining('Go struct field Search.items of type'),
      );
      await expectFailure(
        '[]',
        _threepio(
          'search.cse.list failed: json: cannot unmarshal array into Go value '
          'of type customsearch.Search',
        ),
      );
    });

    test('without queries the query is empty (Go would panic)', () async {
      final tool = _tool(
        (_) async => http.Response('{"items":[{"link":"l"}]}', 200),
      );
      expect(
        await tool.invokableRun(RunContext.background(), '{"query":"q"}'),
        '{"items":[{"link":"l"}]}',
      );
    });
  });

  group('typed results', () {
    test('searchResults maps link, snippet and desc', () async {
      final tool = _tool(
        (_) async => http.Response.bytes(utf8.encode(_mockSearchResult), 200),
      );
      final hits = await tool.searchResults(
        RunContext.background(),
        const GoogleSearchRequest(query: 'q'),
      );
      expect(hits, hasLength(3));
      expect(hits.first.url, 'https://www.cnblogs.com/xueqiuqiu/articles/12955291.html');
      expect(hits.first.title, '图解图算法Pregel: 模型简介与实战案例- 雪球球- 博客园');
      expect(hits.first.snippet, startsWith('May 25, 2020 ... Pregel'));
      expect(hits.first.extra['desc'], startsWith('这篇文章是对之前在&#160;SHLUG'));
      expect(
        const GoogleSimplifiedSearchItem(link: 'l', title: 't').toSearchResult(),
        const SearchResult(title: 't', url: 'l'),
      );
    });

    test('request and result values', () {
      expect(
        GoogleSearchRequest.fromJson(const {'query': 'q', 'num': 2, 'offset': 3, 'lang': 'en'}),
        const GoogleSearchRequest(query: 'q', num: 2, offset: 3, lang: 'en'),
      );
      expect(const GoogleSearchRequest(query: 'q').toJson(), {'query': 'q'});
      expect(
        () => GoogleSearchRequest.fromJson(const {'query': 'q', 'num': '3'}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => GoogleSearchRequest.fromJson(const {'query': 'q', 'num': 2.5}),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'json: cannot unmarshal number 2.5 into Go struct field '
                'SearchRequest.num of type int',
          ),
        ),
      );
      expect(
        const GoogleSearchResult(
          query: 'q',
          items: [GoogleSimplifiedSearchItem(link: 'l', desc: 'd')],
        ).toJson(),
        {
          'query': 'q',
          'items': [
            {'link': 'l', 'desc': 'd'},
          ],
        },
      );
    });
  });

  group('cancellation and timeouts', () {
    test('a cancelled context sends nothing', () async {
      var sent = 0;
      final tool = _tool((_) async {
        sent++;
        return http.Response(_answer([]), 200);
      });
      await expectLater(
        tool.search(
          RunContext.background(cancelToken: CancelToken()..cancel()),
          const GoogleSearchRequest(query: 'q'),
        ),
        throwsA(isA<CancelledException>()),
      );
      expect(sent, 0);
    });

    test('cancelling while the answer is awaited', () async {
      final answer = Completer<http.StreamedResponse>();
      final tool = GoogleSearchTool(
        GoogleSearchConfig(
          apiKey: 'test-key',
          searchEngineId: 'cx',
          httpClient: MockClient.streaming((_, __) => answer.future),
        ),
      );
      final token = CancelToken();
      final call = tool.search(
        RunContext.background(cancelToken: token),
        const GoogleSearchRequest(query: 'q'),
      );
      await pumpEventQueue();
      token.cancel();
      await expectLater(call, throwsA(isA<CancelledException>()));
      answer.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
    });

    test('an injected timeout; the key never shows in errors', () async {
      final answer = Completer<http.StreamedResponse>();
      final tool = GoogleSearchTool(
        GoogleSearchConfig(
          apiKey: 'test-key',
          searchEngineId: 'cx',
          timeout: const Duration(milliseconds: 20),
          httpClient: MockClient.streaming((_, __) => answer.future),
        ),
      );
      await expectLater(
        tool.search(
          RunContext.background(),
          const GoogleSearchRequest(query: 'q'),
        ),
        throwsA(
          _threepio(
            'search.cse.list failed: Get "https://customsearch.googleapis.com/'
            'customsearch/v1?alt=json&cx=cx&prettyPrint=false&q=q": context '
            'deadline exceeded (Client.Timeout exceeded while awaiting '
            'headers)',
          ),
        ),
      );
      answer.complete(
        http.StreamedResponse(const Stream<List<int>>.empty(), 200),
      );
    });

    test('a network error neither shows the key nor carries it', () async {
      final tool = _tool(
        (request) async =>
            throw http.ClientException('Connection refused', request.url),
      );
      final error = await tool
          .search(
            RunContext.background(),
            const GoogleSearchRequest(query: 'q'),
          )
          .then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, _threepioContaining('Connection refused'));
      expect('$error', isNot(contains('test-key')));
    });
  });

  group('client ownership', () {
    test('an injected client is never closed', () async {
      final client = _TrackingClient(
        MockClient((_) async => http.Response(_answer([]), 200)),
      );
      GoogleSearchTool(
        GoogleSearchConfig(
          apiKey: 'test-key',
          searchEngineId: 'cx',
          httpClient: client,
        ),
      ).dispose();
      expect(client.closed, isFalse);
    });

    test('a disposed tool must not be called', () async {
      final tool = GoogleSearchTool(
        const GoogleSearchConfig(apiKey: 'test-key', searchEngineId: 'cx'),
      )
        ..dispose()
        ..dispose();
      await expectLater(
        tool.search(
          RunContext.background(),
          const GoogleSearchRequest(query: 'q'),
        ),
        throwsStateError,
      );
    });
  });
}
