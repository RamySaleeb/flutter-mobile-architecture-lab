import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'catalog.dart';
import 'catalog_controller.dart';
import 'catalog_data.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // Keep browser semantics available for the lifetime of this small demo.
  SemanticsBinding.instance.ensureSemantics();
  runApp(const PocketCatalogApp());
}

ButtonStyle accessibleButtonStyle() => ButtonStyle(
  minimumSize: const WidgetStatePropertyAll(Size(48, 48)),
  side: WidgetStateProperty.resolveWith(
    (states) => states.contains(WidgetState.focused)
        ? const BorderSide(color: Color(0xff17685d), width: 3)
        : null,
  ),
);

class PocketCatalogApp extends StatelessWidget {
  const PocketCatalogApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Pocket Catalog',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: accessibleButtonStyle(),
      ),
      textButtonTheme: TextButtonThemeData(style: accessibleButtonStyle()),
      iconButtonTheme: IconButtonThemeData(style: accessibleButtonStyle()),
      colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff17685d)),
      scaffoldBackgroundColor: const Color(0xfff5f7f3),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
    ),
    home: const CatalogScreen(),
  );
}

class CatalogScreen extends StatefulWidget {
  const CatalogScreen({super.key});
  @override
  State<CatalogScreen> createState() => _CatalogScreenState();
}

class _CatalogScreenState extends State<CatalogScreen> {
  late DemoCatalogService service;
  late CatalogController controller;
  final search = TextEditingController();
  bool raceRunning = false;
  String? raceStatus;
  int session = 0;

  void resetDemo() {
    ++session;
    controller.dispose();
    controller.repository.dispose();
    setState(() {
      service = DemoCatalogService();
      controller = CatalogController(CachedCatalogRepository(service));
      raceRunning = false;
      raceStatus = null;
      search.clear();
    });
    unawaited(controller.load(''));
  }

  Future<void> runRace({bool olderFails = false}) async {
    final currentSession = ++session;
    controller.dispose();
    controller.repository.dispose();
    setState(() {
      // A fresh session prevents cached or in-flight queries hiding the race.
      service = DemoCatalogService(
        delayForQuery: (query) =>
            Duration(milliseconds: query == 'outdoor' ? 3000 : 750),
        failsForQuery: (query) => olderFails && query == 'outdoor',
      );
      controller = CatalogController(CachedCatalogRepository(service));
      raceRunning = true;
      raceStatus =
          '1. Outdoor started first (3 s).\n'
          '2. Workspace started second (0.75 s).';
      search.text = 'workspace';
    });
    final older = controller.load('outdoor', force: true);
    final newer = controller.load('workspace', force: true);
    await newer;
    if (!mounted || currentSession != session) return;
    setState(() {
      raceStatus =
          '3. Workspace finished first. Its results are visible.\n'
          'Outdoor is still pending…';
    });
    await older;
    if (!mounted || currentSession != session) return;
    setState(() {
      raceRunning = false;
      raceStatus = olderFails
          ? '4. Older Outdoor request failed. Workspace stays visible; '
                'the old error cannot replace the current search.'
          : '4. Older Outdoor request finished. Workspace stays visible; '
                'Outdoor only warmed its own cache.';
      // The scenario has ended; ordinary browsing uses the normal delay again.
      service.delayForQuery = null;
      service.failsForQuery = null;
    });
  }

  @override
  void initState() {
    super.initState();
    service = DemoCatalogService();
    controller = CatalogController(CachedCatalogRepository(service));
    unawaited(controller.load(''));
  }

  @override
  void dispose() {
    ++session;
    controller.dispose();
    controller.repository.dispose();
    search.dispose();
    super.dispose();
  }

  void refresh() => unawaited(controller.load(search.text, force: true));

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              final state = controller.state;
              final items = state.snapshot?.items ?? const <CatalogItem>[];
              return FocusTraversalGroup(
                policy: OrderedTraversalPolicy(),
                child: SingleChildScrollView(
                  padding: EdgeInsets.all(
                    MediaQuery.sizeOf(context).width < 480 ? 16 : 24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'POCKET / ARCHITECTURE LAB',
                        style: TextStyle(
                          letterSpacing: 2,
                          fontWeight: FontWeight.w700,
                          color: Color(0xff17685d),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Text(
                        'A calmer way to browse.',
                        style: Theme.of(context).textTheme.headlineLarge
                            ?.copyWith(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Fictional products. Real loading, caching, and recovery behavior.',
                      ),
                      const SizedBox(height: 24),
                      const Text('Search the catalog'),
                      const SizedBox(height: 8),
                      Semantics(
                        label: 'Search the catalog',
                        child: FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: TextField(
                            enabled: !raceRunning,
                            controller: search,
                            textInputAction: TextInputAction.search,
                            onSubmitted: (value) =>
                                unawaited(controller.load(value)),
                            decoration: InputDecoration(
                              hintText: 'Try outdoor',
                              prefixIcon: const Icon(Icons.search),
                              suffixIcon: FocusTraversalOrder(
                                order: const NumericFocusOrder(2),
                                child: IconButton(
                                  tooltip: 'Search',
                                  icon: const Icon(Icons.arrow_forward),
                                  onPressed: raceRunning
                                      ? null
                                      : () => unawaited(
                                          controller.load(search.text),
                                        ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          Semantics(
                            liveRegion: true,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xffe7f2ee),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                state.loading
                                    ? 'Loading catalog…'
                                    : state.snapshot == null
                                    ? 'No data yet'
                                    : state.fromCache
                                    ? 'Session cache'
                                    : 'Fresh from demo service',
                              ),
                            ),
                          ),
                          FocusTraversalOrder(
                            order: const NumericFocusOrder(3),
                            child: OutlinedButton.icon(
                              onPressed: state.loading || raceRunning
                                  ? null
                                  : refresh,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Refresh'),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Card(
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'See a request race',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const Text(
                                'Start a slow Outdoor search, then a fast '
                                'Workspace search. The latest search must win. '
                                'Each run starts a fresh demo session.',
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 8,
                                runSpacing: 8,
                                children: [
                                  FocusTraversalOrder(
                                    order: const NumericFocusOrder(4),
                                    child: OutlinedButton(
                                      onPressed: raceRunning
                                          ? null
                                          : () => unawaited(runRace()),
                                      child: const Text('Run request race'),
                                    ),
                                  ),
                                  FocusTraversalOrder(
                                    order: const NumericFocusOrder(5),
                                    child: OutlinedButton(
                                      onPressed: raceRunning
                                          ? null
                                          : () => unawaited(
                                              runRace(olderFails: true),
                                            ),
                                      child: const Text(
                                        'Run with older failure',
                                      ),
                                    ),
                                  ),
                                  FocusTraversalOrder(
                                    order: const NumericFocusOrder(6),
                                    child: TextButton(
                                      onPressed: resetDemo,
                                      child: const Text('Reset demo'),
                                    ),
                                  ),
                                ],
                              ),
                              if (raceStatus != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Semantics(
                                    liveRegion: true,
                                    child: Text(raceStatus!),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                      if (state.loading)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 12),
                          child: ExcludeSemantics(
                            child: LinearProgressIndicator(),
                          ),
                        ),
                      if (state.error != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Card(
                            color: Theme.of(context).colorScheme.errorContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Semantics(
                                    liveRegion: true,
                                    child: Text(state.error!),
                                  ),
                                  FocusTraversalOrder(
                                    order: const NumericFocusOrder(7),
                                    child: TextButton(
                                      onPressed: refresh,
                                      child: const Text('Retry'),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      if (!state.loading &&
                          state.error == null &&
                          items.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(24),
                          child: Semantics(
                            liveRegion: true,
                            child: Text('No matches. Try another search.'),
                          ),
                        ),
                      const SizedBox(height: 8),
                      for (final item in items)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Card(
                            elevation: 0,
                            color: Colors.white,
                            child: Padding(
                              padding: const EdgeInsets.all(20),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if (MediaQuery.sizeOf(context).width >= 480 &&
                                      MediaQuery.textScalerOf(
                                            context,
                                          ).scale(14) <=
                                          21) ...[
                                    const ExcludeSemantics(
                                      child: CircleAvatar(
                                        child: Icon(Icons.category_outlined),
                                      ),
                                    ),
                                    const SizedBox(width: 16),
                                  ],
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.category.toUpperCase(),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            letterSpacing: 1.5,
                                            color: Color(0xff17685d),
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          item.title,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.titleLarge,
                                        ),
                                        const SizedBox(height: 6),
                                        Text(item.description),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      const SizedBox(height: 16),
                      Card(
                        elevation: 0,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Try the failure path',
                                style: Theme.of(context).textTheme.titleMedium,
                              ),
                              const Text(
                                'These controls simulate service availability. They do not change your device connection.',
                              ),
                              FocusTraversalOrder(
                                order: const NumericFocusOrder(8),
                                child: SwitchListTile(
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Simulate offline'),
                                  value: service.offline,
                                  onChanged: raceRunning
                                      ? null
                                      : (value) => setState(
                                          () => service.offline = value,
                                        ),
                                ),
                              ),
                              FocusTraversalOrder(
                                order: const NumericFocusOrder(9),
                                child: OutlinedButton(
                                  onPressed: state.loading || raceRunning
                                      ? null
                                      : () {
                                          service.failNext = true;
                                          refresh();
                                        },
                                  child: const Text('Fail next refresh'),
                                ),
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Cache lasts only for this session. Search uses the keyboard action or arrow button.',
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    ),
  );
}
