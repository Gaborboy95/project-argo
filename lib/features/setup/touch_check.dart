import 'package:flutter/material.dart';

class TouchCheck extends StatefulWidget {
  const TouchCheck({super.key});
  @override
  State<TouchCheck> createState() => _TouchCheckState();
}

class _TouchCheckState extends State<TouchCheck> {
  final _confirmed = <int>{};
  static const _locations = [
    Alignment.topLeft,
    Alignment.topRight,
    Alignment.bottomLeft,
    Alignment.bottomRight,
  ];
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Stack(
        children: [
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Touch all four corners'),
                Text('${_confirmed.length} of 4 confirmed'),
                TextButton(
                  onPressed: () =>
                      Navigator.pop(context, _confirmed.length == 4),
                  child: Text(
                    _confirmed.length == 4 ? 'Touch confirmed' : 'Back',
                  ),
                ),
              ],
            ),
          ),
          for (var i = 0; i < _locations.length; i++)
            Align(
              alignment: _locations[i],
              child: SizedBox(
                width: 96,
                height: 96,
                child: OutlinedButton(
                  key: ValueKey('touch-corner-$i'),
                  onPressed: () => setState(() => _confirmed.add(i)),
                  child: Icon(
                    _confirmed.contains(i) ? Icons.check : Icons.touch_app,
                  ),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
