import 'package:flutter/material.dart';

/// The New draft: a blank letter-size sheet. In edit mode the whole sheet is
/// one free-typing area; the text becomes a PDF on ✓.
class DraftSheet extends StatefulWidget {
  const DraftSheet({
    super.key,
    required this.text,
    required this.editing,
    required this.onChanged,
    this.topPadding = 0,
    this.onTap,
  });

  final String text;
  final bool editing;
  final ValueChanged<String> onChanged;
  final double topPadding;
  final VoidCallback? onTap;

  @override
  State<DraftSheet> createState() => _DraftSheetState();
}

class _DraftSheetState extends State<DraftSheet> {
  late final _ctl = TextEditingController(text: widget.text);
  final _focus = FocusNode();

  @override
  void didUpdateWidget(DraftSheet old) {
    super.didUpdateWidget(old);
    if (widget.text != _ctl.text) _ctl.text = widget.text;
    if (widget.editing && !old.editing) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _focus.requestFocus(),
      );
    }
  }

  @override
  void dispose() {
    _ctl.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return LayoutBuilder(
      builder: (context, box) {
        final w = box.maxWidth - 16;
        final s = w / 612;
        final style = TextStyle(
          fontSize: 12 * s,
          height: 1.2,
          color: const Color(0xFF111111),
          fontFamily: 'Helvetica',
          fontFamilyFallback: const ['Arial', 'Roboto', 'sans-serif'],
        );
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: widget.editing ? () => _focus.requestFocus() : widget.onTap,
          child: ColoredBox(
            color: bg,
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(8, widget.topPadding + 8, 8, 48),
              child: Container(
                constraints: BoxConstraints(minHeight: 792 * s),
                width: w,
                padding: EdgeInsets.all(72 * s),
                decoration: const BoxDecoration(
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(blurRadius: 2, color: Color(0x33000000)),
                  ],
                ),
                child: widget.editing
                    ? TextField(
                        key: const ValueKey('draft-field'),
                        controller: _ctl,
                        focusNode: _focus,
                        autofocus: true,
                        maxLines: null,
                        keyboardType: TextInputType.multiline,
                        style: style,
                        cursorColor: Theme.of(context).colorScheme.primary,
                        decoration: const InputDecoration.collapsed(
                          hintText: 'Start typing…',
                        ),
                        onChanged: widget.onChanged,
                      )
                    : Text(
                        widget.text.isEmpty
                            ? 'Tap Edit to start typing.'
                            : widget.text,
                        style: widget.text.isEmpty
                            ? style.copyWith(color: const Color(0xFF9E9E9E))
                            : style,
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}
