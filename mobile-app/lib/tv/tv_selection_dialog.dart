import 'package:flutter/material.dart';
import 'tv_ui.dart';

Future<T?> showTvSelection<T>({
  required BuildContext context,
  required String title,
  required List<T> options,
  required String Function(T) label,
  required bool Function(T) selected,
}) =>
    showDialog<T>(
      context: context,
      builder: (context) => Dialog(
        child: SizedBox(
          width: 620,
          height: MediaQuery.sizeOf(context).height * .75,
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: Theme.of(context).textTheme.headlineMedium),
                const SizedBox(height: 22),
                Expanded(
                  child: options.isEmpty
                      ? Center(
                          child: Text(
                            tvText(
                              context,
                              'Список пока не загружен.',
                              'The list is not loaded yet.',
                            ),
                          ),
                        )
                      : SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              for (var index = 0;
                                  index < options.length;
                                  index++) ...[
                                if (index > 0) const SizedBox(height: 12),
                                TvButton(
                                  label: label(options[index]),
                                  autofocus: selected(options[index]) ||
                                      (index == 0 && !options.any(selected)),
                                  selected: selected(options[index]),
                                  onPressed: () =>
                                      Navigator.pop(context, options[index]),
                                ),
                              ],
                            ],
                          ),
                        ),
                ),
                const SizedBox(height: 18),
                TvButton(
                  label: tvText(context, 'Закрыть', 'Close'),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
