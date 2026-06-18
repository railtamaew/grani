import 'package:flutter/material.dart';

import '../theme.dart';

class PrivacyPolicyDocument extends StatelessWidget {
  const PrivacyPolicyDocument({
    super.key,
    this.compact = false,
  });

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final content = _PrivacyPolicyContent.of(context);
    final horizontalGap = compact ? 12.0 : 16.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PrivacyHero(content: content, compact: compact),
        SizedBox(height: compact ? 14 : 18),
        _SummaryCard(content: content, compact: compact),
        SizedBox(height: compact ? 16 : 20),
        for (final section in content.sections) ...[
          _PolicySectionCard(section: section, compact: compact),
          SizedBox(height: horizontalGap),
        ],
      ],
    );
  }
}

class _PrivacyHero extends StatelessWidget {
  const _PrivacyHero({
    required this.content,
    required this.compact,
  });

  final _PrivacyPolicyContent content;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 20 : 24),
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: GraniTheme.radiusSurface,
        shadows: GraniTheme.surfaceRaisedShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            content.eyebrow,
            style: const TextStyle(
              color: GraniTheme.secondaryText,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            content.title,
            style: TextStyle(
              color: GraniTheme.primaryText,
              fontSize: compact ? 28 : 32,
              fontWeight: FontWeight.w500,
              height: 1.08,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            content.intro,
            style: TextStyle(
              color: GraniTheme.primaryText.withOpacity(0.72),
              fontSize: compact ? 14.5 : 15.5,
              height: 1.45,
              fontWeight: FontWeight.w400,
            ),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _PolicyPill(content.version),
              _PolicyPill(content.updated),
              _PolicyPill(content.source),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({
    required this.content,
    required this.compact,
  });

  final _PrivacyPolicyContent content;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 16 : 18),
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: GraniTheme.radiusSurface,
        shadows: GraniTheme.surfaceSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            content.summaryTitle,
            style: const TextStyle(
              color: GraniTheme.primaryText,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          for (final item in content.summary) ...[
            _SummaryItem(item: item),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _SummaryItem extends StatelessWidget {
  const _SummaryItem({required this.item});

  final _PrivacySummaryItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.58),
        borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
        border: Border.all(
          color: GraniTheme.surfaceStroke.withOpacity(0.86),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: const TextStyle(
              color: GraniTheme.primaryText,
              fontSize: 14,
              fontWeight: FontWeight.w700,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.body,
            style: TextStyle(
              color: GraniTheme.primaryText.withOpacity(0.68),
              fontSize: 13.5,
              height: 1.42,
            ),
          ),
        ],
      ),
    );
  }
}

class _PolicySectionCard extends StatelessWidget {
  const _PolicySectionCard({
    required this.section,
    required this.compact,
  });

  final _PolicySection section;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.all(compact ? 18 : 22),
      decoration: GraniTheme.graniSurfaceDecoration(
        radius: GraniTheme.radiusSurface,
        shadows: GraniTheme.surfaceSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            section.title,
            style: TextStyle(
              color: GraniTheme.primaryText,
              fontSize: compact ? 21 : 23,
              fontWeight: FontWeight.w600,
              height: 1.16,
            ),
          ),
          const SizedBox(height: 12),
          for (final block in section.blocks) _PolicyBlockView(block: block),
        ],
      ),
    );
  }
}

class _PolicyBlockView extends StatelessWidget {
  const _PolicyBlockView({required this.block});

  final _PolicyBlock block;

  @override
  Widget build(BuildContext context) {
    switch (block.kind) {
      case _PolicyBlockKind.paragraph:
        return _PolicyParagraph(block.text);
      case _PolicyBlockKind.subtitle:
        return _PolicySubtitle(block.text);
      case _PolicyBlockKind.bullets:
        return _PolicyBulletList(block.items);
      case _PolicyBlockKind.notice:
        return _PolicyNotice(block.title, block.text);
      case _PolicyBlockKind.retention:
        return _RetentionList(block.retentionItems);
    }
  }
}

class _PolicyParagraph extends StatelessWidget {
  const _PolicyParagraph(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(
        text,
        style: TextStyle(
          color: GraniTheme.primaryText.withOpacity(0.74),
          fontSize: 14.5,
          height: 1.5,
        ),
      ),
    );
  }
}

class _PolicySubtitle extends StatelessWidget {
  const _PolicySubtitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: GraniTheme.primaryText,
          fontSize: 16,
          fontWeight: FontWeight.w700,
          height: 1.25,
        ),
      ),
    );
  }
}

class _PolicyBulletList extends StatelessWidget {
  const _PolicyBulletList(this.items);

  final List<String> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 5,
                    height: 5,
                    margin: const EdgeInsets.only(top: 8, right: 10),
                    decoration: BoxDecoration(
                      color: GraniTheme.warmAccent.withOpacity(0.72),
                      shape: BoxShape.circle,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      item,
                      style: TextStyle(
                        color: GraniTheme.primaryText.withOpacity(0.72),
                        fontSize: 14.5,
                        height: 1.42,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _PolicyNotice extends StatelessWidget {
  const _PolicyNotice(this.title, this.text);

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: GraniTheme.surfaceControlGradient,
        borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
        border: Border.all(
          color: GraniTheme.warmAccentSoft.withOpacity(0.28),
        ),
        boxShadow: GraniTheme.surfaceSoftShadow,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: GraniTheme.primaryText,
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            text,
            style: TextStyle(
              color: GraniTheme.primaryText.withOpacity(0.72),
              fontSize: 14,
              height: 1.42,
            ),
          ),
        ],
      ),
    );
  }
}

class _RetentionList extends StatelessWidget {
  const _RetentionList(this.items);

  final List<_RetentionItem> items;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        children: [
          for (final item in items) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.52),
                borderRadius: BorderRadius.circular(GraniTheme.radiusControl),
                border: Border.all(
                  color: GraniTheme.surfaceStroke.withOpacity(0.86),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.category,
                    style: const TextStyle(
                      color: GraniTheme.primaryText,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.purpose,
                    style: TextStyle(
                      color: GraniTheme.primaryText.withOpacity(0.70),
                      fontSize: 13.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Text(
                    item.retention,
                    style: TextStyle(
                      color: GraniTheme.primaryText.withOpacity(0.58),
                      fontSize: 13,
                      height: 1.35,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 9),
          ],
        ],
      ),
    );
  }
}

class _PolicyPill extends StatelessWidget {
  const _PolicyPill(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: GraniTheme.surfaceInset.withOpacity(0.78),
        borderRadius: BorderRadius.circular(GraniTheme.radiusPill),
        border: Border.all(
          color: GraniTheme.surfaceStroke.withOpacity(0.82),
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: GraniTheme.primaryText,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PrivacyPolicyContent {
  const _PrivacyPolicyContent({
    required this.eyebrow,
    required this.title,
    required this.intro,
    required this.version,
    required this.updated,
    required this.source,
    required this.summaryTitle,
    required this.summary,
    required this.sections,
  });

  final String eyebrow;
  final String title;
  final String intro;
  final String version;
  final String updated;
  final String source;
  final String summaryTitle;
  final List<_PrivacySummaryItem> summary;
  final List<_PolicySection> sections;

  static _PrivacyPolicyContent of(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode.toLowerCase();
    return code == 'ru' ? _ru : _en;
  }
}

class _PrivacySummaryItem {
  const _PrivacySummaryItem(this.title, this.body);

  final String title;
  final String body;
}

class _PolicySection {
  const _PolicySection(this.title, this.blocks);

  final String title;
  final List<_PolicyBlock> blocks;
}

enum _PolicyBlockKind { paragraph, subtitle, bullets, notice, retention }

class _PolicyBlock {
  const _PolicyBlock.paragraph(this.text)
      : kind = _PolicyBlockKind.paragraph,
        title = '',
        items = const [],
        retentionItems = const [];

  const _PolicyBlock.subtitle(this.text)
      : kind = _PolicyBlockKind.subtitle,
        title = '',
        items = const [],
        retentionItems = const [];

  const _PolicyBlock.bullets(this.items)
      : kind = _PolicyBlockKind.bullets,
        title = '',
        text = '',
        retentionItems = const [];

  const _PolicyBlock.notice(this.title, this.text)
      : kind = _PolicyBlockKind.notice,
        items = const [],
        retentionItems = const [];

  const _PolicyBlock.retention(this.retentionItems)
      : kind = _PolicyBlockKind.retention,
        title = '',
        text = '',
        items = const [];

  final _PolicyBlockKind kind;
  final String title;
  final String text;
  final List<String> items;
  final List<_RetentionItem> retentionItems;
}

class _RetentionItem {
  const _RetentionItem(this.category, this.purpose, this.retention);

  final String category;
  final String purpose;
  final String retention;
}

const _ru = _PrivacyPolicyContent(
  eyebrow: 'Privacy Policy',
  title: 'Политика конфиденциальности GRANI VPN',
  intro:
      'Документ описывает, какие данные нужны сервису для аккаунта, подписки, VPN-подключения, безопасности и диагностики, а также какие данные мы не собираем.',
  version: 'Версия 2.0',
  updated: 'Обновлено: 1 июня 2026',
  source: 'granilink.com/privacy',
  summaryTitle: 'Коротко',
  summary: [
    _PrivacySummaryItem(
      'Мы не храним содержание трафика.',
      'GRANI VPN не записывает содержимое сайтов, сообщений, файлов или приложений, которые проходят через VPN.',
    ),
    _PrivacySummaryItem(
      'Технические логи существуют.',
      'Они нужны для авторизации, подписок, защиты от злоупотреблений, диагностики ошибок и стабильности VPN.',
    ),
    _PrivacySummaryItem(
      'Данные маршрутизируются через выбранные VPN-серверы.',
      'Инфраструктура может находиться в разных странах в зависимости от выбранной локации.',
    ),
    _PrivacySummaryItem(
      'Платежи обрабатываются платформами.',
      'Мы не получаем полные данные банковских карт; подписки Android обрабатываются через Google Play.',
    ),
  ],
  sections: [
    _PolicySection('1. Общие положения', [
      _PolicyBlock.paragraph(
        'Настоящая Политика конфиденциальности описывает, как GRANI VPN, доступный через приложение GRANI и домены granilink.com, app.granilink.com, api.granilink.com и связанные сервисы, обрабатывает данные пользователей.',
      ),
      _PolicyBlock.paragraph(
        'В документе термины «GRANI», «GRANI VPN», «мы» означают операторов сервиса GRANI VPN. Термины «вы» и «пользователь» означают лицо, которое посещает сайт, устанавливает приложение, создает аккаунт, использует пробный период, подписку или VPN-подключение.',
      ),
      _PolicyBlock.paragraph(
        'Используя сайт, приложение или VPN-сервис, вы подтверждаете, что ознакомились с настоящей Политикой. Если вы не согласны с ней, не используйте сервис.',
      ),
    ]),
    _PolicySection('2. Контакты', [
      _PolicyBlock.paragraph(
        'По вопросам конфиденциальности, удаления данных, доступа к данным и технической поддержки можно обратиться по адресу support@granilink.com.',
      ),
      _PolicyBlock.paragraph('Основной сайт: https://granilink.com.'),
    ]),
    _PolicySection('3. Какие данные мы обрабатываем', [
      _PolicyBlock.subtitle('3.1. Аккаунт и авторизация'),
      _PolicyBlock.bullets([
        'Email-адрес и данные, необходимые для входа в аккаунт.',
        'Код подтверждения email и технические записи о факте подтверждения.',
        'При входе через Google: идентификатор Google-аккаунта, email, имя или отображаемое имя, если они предоставлены Google.',
        'Токены сессии и служебные признаки авторизации.',
      ]),
      _PolicyBlock.subtitle('3.2. Подписка и платежи'),
      _PolicyBlock.bullets([
        'Статус пробного периода или подписки, тариф, срок действия, история изменений статуса.',
        'Идентификаторы покупки, purchase token, package name и иные данные, необходимые для проверки подписки через Google Play.',
        'Мы не получаем и не храним полные данные банковских карт. Платежные данные обрабатываются платежными платформами и магазинами приложений.',
      ]),
      _PolicyBlock.subtitle('3.3. Устройство и приложение'),
      _PolicyBlock.bullets([
        'Идентификатор устройства в системе GRANI, используемый для лимита устройств и управления доступом.',
        'Платформа, версия ОС, версия приложения, build number, язык интерфейса, настройки приложения.',
        'Список устройств аккаунта, статус текущего устройства и данные, необходимые для выхода или удаления устройства из аккаунта.',
      ]),
      _PolicyBlock.subtitle('3.4. VPN-сессии и серверы'),
      _PolicyBlock.bullets([
        'Выбранный VPN-сервер, страна или локация сервера, протокол, время начала и окончания сессии.',
        'Состояние подключения, этапы подключения, коды ошибок, request id, correlation id и технические признаки выполнения команд.',
        'Служебные ключи и параметры, необходимые для настройки VPN-подключения на устройстве и сервере.',
      ]),
      _PolicyBlock.subtitle('3.5. Технические логи сайта, API и приложения'),
      _PolicyBlock.bullets([
        'IP-адрес, user-agent, URL запроса, время запроса, HTTP-статус, request id и технические заголовки, которые обрабатываются web/API-инфраструктурой.',
        'Диагностические события приложения: ошибки подключения, состояние VPN-пайплайна, выбранный server_id/protocol, сетевые таймауты и результаты health-check.',
        'Логи контейнеров, nginx, backend, фоновых задач и систем мониторинга, необходимые для стабильности и безопасности сервиса.',
      ]),
    ]),
    _PolicySection('4. Что мы не собираем в рамках VPN', [
      _PolicyBlock.notice(
        'No traffic content logging',
        'GRANI VPN не предназначен для записи содержания вашего интернет-трафика. Мы не сохраняем содержимое сайтов, сообщений, файлов, звонков, DNS-содержимое как историю просмотра или содержимое приложений.',
      ),
      _PolicyBlock.bullets([
        'Мы не создаем историю посещенных сайтов пользователя как продуктовую функцию.',
        'Мы не сохраняем содержание страниц, сообщений, передаваемых файлов или медиа.',
        'Мы не получаем контакты, фотографии, видео и персональные файлы на устройстве, если они не предоставлены вами напрямую в обращении в поддержку.',
        'Мы не используем VPN-трафик для продажи поведенческих профилей или таргетированной рекламы.',
      ]),
      _PolicyBlock.paragraph(
        'При этом для работы VPN любые VPN-серверы технически обрабатывают сетевые пакеты в момент передачи. На уровне инфраструктуры могут возникать краткосрочные технические записи, необходимые для маршрутизации, защиты от злоупотреблений, диагностики аварий и соблюдения требований закона.',
      ),
    ]),
    _PolicySection('5. Цели обработки', [
      _PolicyBlock.bullets([
        'Создание и обслуживание аккаунта.',
        'Предоставление пробного периода, подписки и VPN-доступа.',
        'Выбор сервера, подготовка конфигурации и управление VPN-сессией.',
        'Ограничение количества устройств согласно тарифу.',
        'Проверка покупок и статуса подписки.',
        'Техническая поддержка, диагностика ошибок и улучшение стабильности приложения.',
        'Защита сервиса от злоупотреблений, атак, автоматизированных запросов и мошенничества.',
        'Соблюдение применимых юридических требований.',
      ]),
    ]),
    _PolicySection('6. Правовые основания', [
      _PolicyBlock.paragraph(
        'В зависимости от юрисдикции и конкретного сценария мы обрабатываем данные на основании исполнения договора с пользователем, законного интереса в обеспечении безопасности и стабильности сервиса, согласия пользователя, а также выполнения юридических обязанностей.',
      ),
    ]),
    _PolicySection('7. Третьи лица и инфраструктура', [
      _PolicyBlock.paragraph(
        'Мы можем использовать поставщиков инфраструктуры и сервисов, которые помогают обеспечивать работу GRANI VPN:',
      ),
      _PolicyBlock.bullets([
        'хостинг и дата-центры для backend, VPN-серверов и баз данных;',
        'Cloudflare или аналогичные сервисы для защиты и доставки web/API-трафика, если они используются для соответствующих доменов;',
        'Google и Google Play для входа, проверки подписок и обработки платежей на Android;',
        'почтовые сервисы для отправки кодов, уведомлений и ответов поддержки;',
        'инструменты мониторинга, логирования и диагностики для стабильности сервиса.',
      ]),
      _PolicyBlock.paragraph(
        'VPN endpoints и VPN-порты не должны проксироваться через Cloudflare как обычный web-трафик; они работают как отдельная VPN-инфраструктура. Мы не продаем персональные данные третьим лицам.',
      ),
    ]),
    _PolicySection('8. Сроки хранения', [
      _PolicyBlock.retention([
        _RetentionItem(
          'Аккаунт и email',
          'Авторизация, поддержка, управление подпиской',
          'Пока аккаунт активен и далее в пределах законных требований',
        ),
        _RetentionItem(
          'Подписка и покупки',
          'Проверка доступа, бухгалтерские и юридические требования',
          'Пока требуется для исполнения договора и закона',
        ),
        _RetentionItem(
          'Устройства аккаунта',
          'Лимит устройств, безопасность аккаунта',
          'Пока устройство привязано к аккаунту или пока нужен аудит безопасности',
        ),
        _RetentionItem(
          'VPN-сессии и технические события подключения',
          'Работа сервиса, диагностика, защита от злоупотреблений',
          'Обычно до 30 дней, если не требуется более долгий срок для расследования инцидента',
        ),
        _RetentionItem(
          'Backend/API/container логи',
          'Стабильность, мониторинг, безопасность',
          'Обычно до 90 дней в рамках ротации логов, если не требуется более долгий срок по закону или инциденту',
        ),
        _RetentionItem(
          'Обращения в поддержку',
          'Ответ на запрос и история решения проблемы',
          'Пока необходимо для поддержки и защиты прав сторон',
        ),
      ]),
    ]),
    _PolicySection('9. Безопасность', [
      _PolicyBlock.bullets([
        'Передача данных между приложением, сайтом и API защищается TLS, где это применимо.',
        'Доступ к production-инфраструктуре ограничивается техническими и организационными мерами.',
        'Секреты, ключи, токены и платежные идентификаторы обрабатываются как чувствительные технические данные.',
        'Мы применяем мониторинг, журналы событий, контейнеризацию, сетевые ограничения и обновления инфраструктуры.',
      ]),
      _PolicyBlock.paragraph(
        'Ни один сервис не может гарантировать абсолютную безопасность. При обнаружении существенного инцидента мы будем действовать в соответствии с применимыми требованиями закона и уведомления пользователей.',
      ),
    ]),
    _PolicySection('10. Ваши права', [
      _PolicyBlock.paragraph(
        'В зависимости от применимого законодательства вы можете запросить доступ к данным, исправление, удаление, ограничение обработки, переносимость, отзыв согласия или возражение против обработки.',
      ),
      _PolicyBlock.paragraph(
        'Для запроса напишите на support@granilink.com. Мы можем запросить подтверждение личности, чтобы не раскрыть данные постороннему лицу. Обычно мы отвечаем в течение 30 дней, если иной срок не установлен законом.',
      ),
    ]),
    _PolicySection('11. Cookies и сайт', [
      _PolicyBlock.paragraph(
        'Сайт GRANI может использовать необходимые cookies, локальное хранилище и технические журналы web-сервера для работы сайта, защиты от злоупотреблений и измерения стабильности. Вы можете управлять cookies через настройки браузера.',
      ),
    ]),
    _PolicySection('12. Международная передача данных', [
      _PolicyBlock.paragraph(
        'GRANI VPN работает с VPN-серверами и инфраструктурой в разных странах. В зависимости от выбранной локации VPN и используемой инфраструктуры данные могут обрабатываться за пределами вашей страны. Мы применяем технические и договорные меры защиты там, где это требуется и возможно.',
      ),
    ]),
    _PolicySection('13. Возраст', [
      _PolicyBlock.paragraph(
        'Сервис предназначен для пользователей, достигших возраста, необходимого для заключения договора и использования цифровых сервисов в своей юрисдикции. Мы не предназначаем сервис для детей и не собираем намеренно данные детей.',
      ),
    ]),
    _PolicySection('14. Изменения политики', [
      _PolicyBlock.paragraph(
        'Мы можем обновлять Политику при изменении продукта, инфраструктуры, требований магазинов приложений или законодательства. Новая версия публикуется по адресу https://granilink.com/privacy. Существенные изменения могут дополнительно сообщаться в приложении, по email или иным доступным способом.',
      ),
    ]),
    _PolicySection('15. Версия документа', [
      _PolicyBlock.paragraph(
        'Версия: 2.0. Дата обновления: 1 июня 2026 года. Эта версия заменяет предыдущую редакцию 1.0 от 9 октября 2025 года.',
      ),
    ]),
  ],
);

const _en = _PrivacyPolicyContent(
  eyebrow: 'Privacy Policy',
  title: 'GRANI VPN Privacy Policy',
  intro:
      'This document explains what data the service needs for accounts, subscriptions, VPN connectivity, security and diagnostics, and what data we do not collect.',
  version: 'Version 2.0',
  updated: 'Updated: June 1, 2026',
  source: 'granilink.com/privacy',
  summaryTitle: 'In Short',
  summary: [
    _PrivacySummaryItem(
      'We do not store traffic content.',
      'GRANI VPN does not record the content of websites, messages, files or applications that pass through the VPN.',
    ),
    _PrivacySummaryItem(
      'Technical logs exist.',
      'They are required for authentication, subscriptions, abuse prevention, error diagnostics and VPN stability.',
    ),
    _PrivacySummaryItem(
      'Data is routed through selected VPN servers.',
      'Infrastructure may be located in different countries depending on the location selected.',
    ),
    _PrivacySummaryItem(
      'Payments are processed by platforms.',
      'We do not receive full bank card details; Android subscriptions are processed through Google Play.',
    ),
  ],
  sections: [
    _PolicySection('1. Overview', [
      _PolicyBlock.paragraph(
        'This Privacy Policy explains how GRANI VPN, available through the GRANI application and the domains granilink.com, app.granilink.com, api.granilink.com and related services, processes user data.',
      ),
      _PolicyBlock.paragraph(
        '“GRANI”, “GRANI VPN”, “we” and “us” mean the operators of the GRANI VPN service. “You” and “user” mean a person who visits the website, installs the application, creates an account, uses a trial, subscription or VPN connection.',
      ),
      _PolicyBlock.paragraph(
        'By using the website, application or VPN service, you confirm that you have read this Policy. If you do not agree with it, do not use the service.',
      ),
    ]),
    _PolicySection('2. Contact', [
      _PolicyBlock.paragraph(
        'For privacy, deletion, access and support requests, contact support@granilink.com.',
      ),
      _PolicyBlock.paragraph('Main website: https://granilink.com.'),
    ]),
    _PolicySection('3. Data We Process', [
      _PolicyBlock.subtitle('3.1. Account and authentication'),
      _PolicyBlock.bullets([
        'Email address and data required to sign in.',
        'Email verification codes and technical records of verification.',
        'For Google sign-in: Google account identifier, email, name or display name if provided by Google.',
        'Session tokens and service authentication flags.',
      ]),
      _PolicyBlock.subtitle('3.2. Subscription and payments'),
      _PolicyBlock.bullets([
        'Trial or subscription status, plan, expiration date and subscription status history.',
        'Purchase identifiers, purchase token, package name and other data needed to verify subscriptions through Google Play.',
        'We do not receive or store full bank card details. Payment data is processed by payment platforms and app stores.',
      ]),
      _PolicyBlock.subtitle('3.3. Device and application'),
      _PolicyBlock.bullets([
        'GRANI device identifier used for device limits and access control.',
        'Platform, OS version, app version, build number, interface language and application settings.',
        'Account device list, current device status and data needed to sign out or remove a device from the account.',
      ]),
      _PolicyBlock.subtitle('3.4. VPN sessions and servers'),
      _PolicyBlock.bullets([
        'Selected VPN server, country or location, protocol, session start and end time.',
        'Connection state, connection stages, error codes, request id, correlation id and technical command execution markers.',
        'Service keys and parameters required to configure the VPN connection on the device and server.',
      ]),
      _PolicyBlock.subtitle('3.5. Website, API and application technical logs'),
      _PolicyBlock.bullets([
        'IP address, user-agent, request URL, request time, HTTP status, request id and technical headers processed by web/API infrastructure.',
        'Application diagnostics: connection errors, VPN pipeline state, selected server_id/protocol, network timeouts and health-check results.',
        'Container, nginx, backend, background job and monitoring logs required for service stability and security.',
      ]),
    ]),
    _PolicySection('4. What We Do Not Collect in VPN Traffic', [
      _PolicyBlock.notice(
        'No traffic content logging',
        'GRANI VPN is not designed to record the content of your Internet traffic. We do not store the content of websites, messages, files, calls, DNS content as browsing history, or application content.',
      ),
      _PolicyBlock.bullets([
        'We do not create a user browsing history as a product feature.',
        'We do not store page content, messages, transferred files or media.',
        'We do not access contacts, photos, videos or personal files on your device unless you provide them directly in a support request.',
        'We do not use VPN traffic to sell behavioral profiles or targeted advertising.',
      ]),
      _PolicyBlock.paragraph(
        'However, to provide VPN connectivity, VPN servers technically process network packets in transit. Infrastructure may generate short-term technical records required for routing, abuse prevention, incident diagnostics and legal compliance.',
      ),
    ]),
    _PolicySection('5. Purposes of Processing', [
      _PolicyBlock.bullets([
        'Creating and maintaining your account.',
        'Providing trial, subscription and VPN access.',
        'Selecting a server, preparing configuration and managing VPN sessions.',
        'Enforcing device limits according to your plan.',
        'Verifying purchases and subscription status.',
        'Providing support, diagnosing errors and improving application stability.',
        'Protecting the service against abuse, attacks, automated requests and fraud.',
        'Complying with applicable legal requirements.',
      ]),
    ]),
    _PolicySection('6. Legal Bases', [
      _PolicyBlock.paragraph(
        'Depending on the jurisdiction and scenario, we process data to perform our agreement with you, based on our legitimate interest in service security and stability, based on your consent, and to comply with legal obligations.',
      ),
    ]),
    _PolicySection('7. Third Parties and Infrastructure', [
      _PolicyBlock.paragraph(
        'We may use infrastructure and service providers that help operate GRANI VPN:',
      ),
      _PolicyBlock.bullets([
        'hosting and data centers for backend, VPN servers and databases;',
        'Cloudflare or similar services for protection and delivery of web/API traffic, where used for relevant domains;',
        'Google and Google Play for sign-in, subscription verification and Android payment processing;',
        'email services for codes, notifications and support replies;',
        'monitoring, logging and diagnostics tools for service stability.',
      ]),
      _PolicyBlock.paragraph(
        'VPN endpoints and VPN ports should not be proxied through Cloudflare as ordinary web traffic; they operate as separate VPN infrastructure. We do not sell personal data.',
      ),
    ]),
    _PolicySection('8. Retention', [
      _PolicyBlock.retention([
        _RetentionItem(
          'Account and email',
          'Authentication, support, subscription management',
          'While the account is active and thereafter as required by law',
        ),
        _RetentionItem(
          'Subscription and purchases',
          'Access verification, accounting and legal requirements',
          'As long as needed to perform the agreement and comply with law',
        ),
        _RetentionItem(
          'Account devices',
          'Device limits and account security',
          'While the device is linked to the account or needed for security audit',
        ),
        _RetentionItem(
          'VPN sessions and connection technical events',
          'Service operation, diagnostics, abuse prevention',
          'Usually up to 30 days unless longer retention is needed for an incident',
        ),
        _RetentionItem(
          'Backend/API/container logs',
          'Stability, monitoring and security',
          'Usually up to 90 days under log rotation unless longer retention is required by law or incident handling',
        ),
        _RetentionItem(
          'Support requests',
          'Answering requests and preserving issue history',
          'As long as needed for support and protection of rights',
        ),
      ]),
    ]),
    _PolicySection('9. Security', [
      _PolicyBlock.bullets([
        'Data transfer between the application, website and API is protected with TLS where applicable.',
        'Access to production infrastructure is restricted by technical and organizational controls.',
        'Secrets, keys, tokens and payment identifiers are treated as sensitive technical data.',
        'We use monitoring, event logs, containerization, network restrictions and infrastructure updates.',
      ]),
      _PolicyBlock.paragraph(
        'No service can guarantee absolute security. If we identify a material incident, we will act according to applicable legal and user notification requirements.',
      ),
    ]),
    _PolicySection('10. Your Rights', [
      _PolicyBlock.paragraph(
        'Depending on applicable law, you may request access, correction, deletion, restriction of processing, portability, withdrawal of consent or objection to processing.',
      ),
      _PolicyBlock.paragraph(
        'To make a request, contact support@granilink.com. We may ask you to verify your identity to avoid disclosing data to another person. We typically respond within 30 days unless another period is required by law.',
      ),
    ]),
    _PolicySection('11. Cookies and Website', [
      _PolicyBlock.paragraph(
        'The GRANI website may use necessary cookies, local storage and technical web server logs for website operation, abuse prevention and stability measurement. You can manage cookies in your browser settings.',
      ),
    ]),
    _PolicySection('12. International Transfers', [
      _PolicyBlock.paragraph(
        'GRANI VPN operates VPN servers and infrastructure in different countries. Depending on the selected VPN location and infrastructure used, data may be processed outside your country. We apply technical and contractual safeguards where required and feasible.',
      ),
    ]),
    _PolicySection('13. Age', [
      _PolicyBlock.paragraph(
        'The service is intended for users who are old enough to enter into an agreement and use digital services in their jurisdiction. The service is not directed to children and we do not knowingly collect children’s data.',
      ),
    ]),
    _PolicySection('14. Changes to This Policy', [
      _PolicyBlock.paragraph(
        'We may update this Policy when the product, infrastructure, app store requirements or law changes. The new version is published at https://granilink.com/privacy. Material changes may also be communicated in the application, by email or by another available method.',
      ),
    ]),
    _PolicySection('15. Document Version', [
      _PolicyBlock.paragraph(
        'Version: 2.0. Updated: June 1, 2026. This version replaces version 1.0 dated October 9, 2025.',
      ),
    ]),
  ],
);
