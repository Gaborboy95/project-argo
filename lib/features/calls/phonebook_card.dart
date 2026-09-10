import 'package:flutter/material.dart';

/// A bounded, transient PBAP page. Choosing a number never places a call.
class PhonebookCard extends StatefulWidget {
  const PhonebookCard({
    required this.book,
    required this.enabled,
    required this.request,
    required this.choose,
    super.key,
  });
  final Map<String, dynamic>? book;
  final bool enabled;
  final Future<void> Function(String action, {String target}) request;
  final void Function(String number) choose;
  @override
  State<PhonebookCard> createState() => _PhonebookCardState();
}

class _PhonebookCardState extends State<PhonebookCard> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final book = widget.book;
    final loading = book?['busy'] == true;
    final recent = book?['kind'] == 'recent';
    final offset = book?['offset'] as int? ?? 0;
    final entries = (book?['entries'] as List? ?? []).where(
      (e) => '${e['name']} ${(e['numbers'] as List).join(' ')}'
          .toLowerCase()
          .contains(query.toLowerCase()),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 32),
        Text(
          'Phone contacts and recent calls',
          style: Theme.of(context).textTheme.titleLarge,
        ),
        const Text(
          'Import from the connected phone after approving Bluetooth contact/call-history sharing. Entries stay only until disconnect or Clear. Choosing a number fills the dial field; press Call separately.',
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: widget.enabled && !loading
                  ? () => widget.request('callsPhonebook', target: 'contacts:0')
                  : null,
              child: const Text('Import contacts'),
            ),
            OutlinedButton(
              onPressed: widget.enabled && !loading
                  ? () => widget.request('callsPhonebook', target: 'recent:0')
                  : null,
              child: const Text('Import recent calls'),
            ),
            TextButton(
              onPressed: () => widget.request('callsPhonebookClear'),
              child: Text(loading ? 'Cancel import' : 'Clear'),
            ),
          ],
        ),
        if (loading) const LinearProgressIndicator(),
        Text(book?['detail'] as String? ?? 'No contacts imported'),
        if ((book?['entries'] as List? ?? []).isNotEmpty) ...[
          Text(
            recent ? 'Recent calls — phone-provided order' : 'Contacts',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          TextField(
            decoration: const InputDecoration(labelText: 'Search this page'),
            onChanged: (v) => setState(() => query = v),
          ),
          for (final entry in entries) ...[
            for (final number in entry['numbers'] as List)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry['name'] as String),
                subtitle: Text(number as String),
                trailing: const Icon(Icons.north),
                onTap: widget.enabled ? () => widget.choose(number) : null,
              ),
            if ((entry['numbers'] as List).isEmpty)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(entry['name'] as String),
                subtitle: const Text('No supported telephone number'),
              ),
          ],
        ],
        if (offset > 0 || book?['more'] == true)
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton(
                onPressed: widget.enabled && !loading && offset > 0
                    ? () => widget.request(
                        'callsPhonebook',
                        target:
                            '${recent ? 'recent' : 'contacts'}:${(offset - 40).clamp(0, 1000)}',
                      )
                    : null,
                child: const Text('Previous page'),
              ),
              OutlinedButton(
                onPressed: widget.enabled && !loading && book?['more'] == true
                    ? () => widget.request(
                        'callsPhonebook',
                        target:
                            '${recent ? 'recent' : 'contacts'}:${offset + 40}',
                      )
                    : null,
                child: const Text('Next page'),
              ),
            ],
          ),
      ],
    );
  }
}
