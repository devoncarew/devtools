import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vm_service/vm_service.dart';

import '../common_widgets.dart';
import '../globals.dart';
import '../table.dart';
import '../table_data.dart';
import '../theme.dart';
import '../utils.dart';

class ImageCacheArea extends StatefulWidget {
  @override
  _ImageCacheAreaState createState() => _ImageCacheAreaState();
}

class CacheEntry {
  CacheEntry(this.map, this.type);

  final Map map;

  final String type;

  String get description => map['description'];

  int get sizeBytes => map['sizeBytes'];

  bool get hasDimensions => map.containsKey('width');

  int get width => map['width'];

  int get height => map['height'];

  bool get alsoLive => map['live'] == true;
}

class DescriptionColumn extends ColumnData<CacheEntry>
    implements ColumnRenderer<CacheEntry> {
  DescriptionColumn(this.items) : super.wide('Description');

  final List<CacheEntry> items;

  @override
  dynamic getValue(CacheEntry dataObject) => dataObject.description;

  @override
  String getTooltip(CacheEntry dataObject) => dataObject.description;

  @override
  Widget build(BuildContext context, CacheEntry data) {
    final value = getDisplayValue(data);

    return Tooltip(
      message: value,
      waitDuration: tooltipWait,
      child: Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: fixedFontStyle(context),
      ),
    );
  }

  @override
  int compare(CacheEntry a, CacheEntry b) {
    // Here, we sort by the intrinsic cache order.
    return items.indexOf(a) - items.indexOf(b);
  }
}

class DimensionsColumn extends ColumnData<CacheEntry> {
  DimensionsColumn()
      : super('Dimensions',
            alignment: ColumnAlignment.right, fixedWidthPx: 100);

  @override
  dynamic getValue(CacheEntry dataObject) {
    if (!dataObject.hasDimensions) return null;

    return '${dataObject.width}x${dataObject.height}';
  }

  @override
  int compare(CacheEntry a, CacheEntry b) {
    final int aDim = (a.width ?? 0) * (a.height ?? 0);
    final int bDim = (b.width ?? 0) * (b.height ?? 0);
    return aDim - bDim;
  }
}

class SizeColumn extends ColumnData<CacheEntry> {
  SizeColumn()
      : super('Size', alignment: ColumnAlignment.right, fixedWidthPx: 90);

  @override
  dynamic getValue(CacheEntry dataObject) => dataObject.sizeBytes;

  @override
  String getDisplayValue(CacheEntry dataObject) {
    return dataObject.sizeBytes == null
        ? ''
        : '${printKb(dataObject.sizeBytes)}kb';
  }

  @override
  bool get numeric => true;

  @override
  int compare(CacheEntry a, CacheEntry b) {
    final int aSize = a.sizeBytes ?? 0;
    final int bSize = b.sizeBytes ?? 0;
    return aSize - bSize;
  }
}

class KindColumn extends ColumnData<CacheEntry> {
  KindColumn()
      : super('Type', alignment: ColumnAlignment.right, fixedWidthPx: 100);

  @override
  dynamic getValue(CacheEntry dataObject) {
    if (dataObject.alsoLive) {
      return '${dataObject.type},live';
    } else {
      return dataObject.type;
    }
  }
}

// todo: write an image cache controller

class _ImageCacheAreaState extends State<ImageCacheArea> {
  _ImageCacheAreaState() {
    description = DescriptionColumn(items);
    _updateDwell = CallbackDwell(_update);
  }

  final List<CacheEntry> items = [];
  StreamSubscription sub;

  int maximumSizeBytes = 0;

  CallbackDwell _updateDwell;

  ColumnData<CacheEntry> description;
  static final ColumnData<CacheEntry> dimensions = DimensionsColumn();
  static final ColumnData<CacheEntry> size = SizeColumn();
  static final ColumnData<CacheEntry> kind = KindColumn();

  @override
  void initState() {
    super.initState();

    _update();

    sub = serviceManager.service
        .onEvent(EventKind.kExtension)
        .where((event) => event.extensionKind.contains('ImageCache'))
        .listen((event) {
      _updateDwell.invoke();
    });
  }

  void _update() {
    if (!mounted) return;

    serviceManager.service
        .callServiceExtension(
      'ext.flutter.imageCache.getInfo',
      isolateId: serviceManager.isolateManager.selectedIsolate.id,
    )
        .then((Response response) {
      final Map<String, dynamic> data = response.json;
      if (!mounted) return;

      setState(() {
        maximumSizeBytes = data['maximumSizeBytes'];

        items.clear();
        items.addAll(
            (data['cachedImages'] as List).map((m) => CacheEntry(m, 'cache')));
        items.addAll(
            (data['liveImages'] as List).map((m) => CacheEntry(m, 'live')));
      });
    });
  }

  @override
  void dispose() {
    super.dispose();

    sub?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final List<CacheEntry> cacheItems =
        items.where((entry) => entry.type == 'cache').toList();

    int cacheSize = 0;
    int liveSize = 0;
    for (var entry in items) {
      if (entry.sizeBytes == null) continue;

      if (entry.type == 'cache') {
        cacheSize += entry.sizeBytes;
      } else {
        liveSize += entry.sizeBytes;
      }
    }

    return Column(
      children: [
        Row(
          children: [
            const Expanded(child: SizedBox(width: defaultSpacing)),
            Text('${cacheItems.length} images cached using '
                '${printMb(cacheSize)} MB'
                ' (${items.length - cacheItems.length} additional live images '
                'using ${printMb(liveSize)} MB)'),
            const SizedBox(width: defaultSpacing),
            RaisedButton(
              child: const Text('Clear cache'),
              onPressed: () async {
                await serviceManager.service.callServiceExtension(
                  'ext.flutter.imageCache.clear',
                  isolateId: serviceManager.isolateManager.selectedIsolate.id,
                );
              },
            ),
          ],
        ),
        const SizedBox(height: denseRowSpacing),
        Expanded(
          child: OutlineDecoration(
            child: FlatTable<CacheEntry>(
              columns: [description, dimensions, size, kind],
              data: List.from(items),
              keyFactory: (CacheEntry data) =>
                  ValueKey<int>(items.indexOf(data)),
              onItemSelected: (item) {
                // no-op
              },
              sortColumn: description,
              sortDirection: SortDirection.ascending,
              //rowHeight: 50.0,
            ),
          ),
        ),
      ],
    );
  }
}
