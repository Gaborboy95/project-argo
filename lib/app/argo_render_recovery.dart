import 'package:flutter/widgets.dart';

/// App-level escape hatch for a failed route, without restarting services.
class ArgoRenderRecoveryScope extends InheritedWidget {
  const ArgoRenderRecoveryScope({
    super.key,
    required this.returnHome,
    required super.child,
  });

  final VoidCallback returnHome;

  static ArgoRenderRecoveryScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<ArgoRenderRecoveryScope>();

  @override
  bool updateShouldNotify(ArgoRenderRecoveryScope oldWidget) =>
      returnHome != oldWidget.returnHome;
}

/// Keep release build errors visible and escapable. This deliberately uses no
/// Material theme, localization, scroll state or exception text: those may be
/// the failing dependencies, and complete diagnostics already belong in capture.
class ArgoRenderFailure extends StatelessWidget {
  const ArgoRenderFailure({super.key});

  @override
  Widget build(BuildContext context) {
    final recover = ArgoRenderRecoveryScope.maybeOf(context)?.returnHome;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.hasBoundedWidth
              ? constraints.maxWidth
              : 320.0;
          final height = constraints.hasBoundedHeight
              ? constraints.maxHeight
              : 48.0;
          final spacious = width >= 240 && height >= 200;
          return SizedBox(
            width: width,
            height: height,
            child: ClipRect(
              child: ColoredBox(
                color: const Color(0xff211e26),
                child: Semantics(
                  button: recover != null,
                  label: recover == null
                      ? 'View unavailable'
                      : 'Return to Home',
                  child: GestureDetector(
                    key: const ValueKey('render-failure-return-home'),
                    behavior: HitTestBehavior.opaque,
                    onTap: recover,
                    child: Center(
                      child: spacious
                          ? Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Text(
                                    'This view could not be displayed.',
                                    textScaler: TextScaler.noScaling,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: Color(0xffe6e1e9),
                                      fontSize: 18,
                                    ),
                                  ),
                                  if (recover != null) ...[
                                    const SizedBox(height: 20),
                                    const DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: Color(0xff494153),
                                        borderRadius: BorderRadius.all(
                                          Radius.circular(12),
                                        ),
                                      ),
                                      child: Padding(
                                        padding: EdgeInsets.symmetric(
                                          horizontal: 20,
                                          vertical: 14,
                                        ),
                                        child: Text(
                                          'Return to Home',
                                          textScaler: TextScaler.noScaling,
                                          style: TextStyle(
                                            color: Color(0xffe6e1e9),
                                            fontSize: 18,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            )
                          : const FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Text(
                                'View unavailable',
                                textScaler: TextScaler.noScaling,
                                style: TextStyle(
                                  color: Color(0xffe6e1e9),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
