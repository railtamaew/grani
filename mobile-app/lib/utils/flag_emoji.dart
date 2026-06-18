import 'package:flutter/material.dart';

/// Утилита для получения эмодзи флага по названию страны
class FlagEmoji {
  /// Маппинг названий стран на коды ISO 3166-1 alpha-2
  static const Map<String, String> _countryToCode = {
    'Россия': 'RU',
    'Russia': 'RU',
    'RU': 'RU',
    'Венгрия': 'HU',
    'Hungary': 'HU',
    'HU': 'HU',
    'США': 'US',
    'United States': 'US',
    'USA': 'US',
    'US': 'US',
    'Германия': 'DE',
    'Germany': 'DE',
    'DE': 'DE',
    'Франция': 'FR',
    'France': 'FR',
    'FR': 'FR',
    'Великобритания': 'GB',
    'United Kingdom': 'GB',
    'UK': 'GB',
    'GB': 'GB',
    'Нидерланды': 'NL',
    'Netherlands': 'NL',
    'NL': 'NL',
    'Польша': 'PL',
    'Poland': 'PL',
    'PL': 'PL',
    'Испания': 'ES',
    'Spain': 'ES',
    'ES': 'ES',
    'Италия': 'IT',
    'Italy': 'IT',
    'IT': 'IT',
    'Канада': 'CA',
    'Canada': 'CA',
    'CA': 'CA',
    'Австралия': 'AU',
    'Australia': 'AU',
    'AU': 'AU',
    'Япония': 'JP',
    'Japan': 'JP',
    'JP': 'JP',
    'Китай': 'CN',
    'China': 'CN',
    'CN': 'CN',
    'Бразилия': 'BR',
    'Brazil': 'BR',
    'BR': 'BR',
    'Индия': 'IN',
    'India': 'IN',
    'IN': 'IN',
    'Южная Корея': 'KR',
    'South Korea': 'KR',
    'KR': 'KR',
    'Сингапур': 'SG',
    'Singapore': 'SG',
    'SG': 'SG',
    'Швейцария': 'CH',
    'Switzerland': 'CH',
    'CH': 'CH',
    'Швеция': 'SE',
    'Sweden': 'SE',
    'SE': 'SE',
    'Норвегия': 'NO',
    'Norway': 'NO',
    'NO': 'NO',
    'Дания': 'DK',
    'Denmark': 'DK',
    'DK': 'DK',
    'Финляндия': 'FI',
    'Finland': 'FI',
    'FI': 'FI',
    'Бельгия': 'BE',
    'Belgium': 'BE',
    'BE': 'BE',
    'Австрия': 'AT',
    'Austria': 'AT',
    'AT': 'AT',
    'Чехия': 'CZ',
    'Czech Republic': 'CZ',
    'CZ': 'CZ',
    'Португалия': 'PT',
    'Portugal': 'PT',
    'PT': 'PT',
    'Греция': 'GR',
    'Greece': 'GR',
    'GR': 'GR',
    'Турция': 'TR',
    'Turkey': 'TR',
    'TR': 'TR',
    'Израиль': 'IL',
    'Israel': 'IL',
    'IL': 'IL',
    'ОАЭ': 'AE',
    'United Arab Emirates': 'AE',
    'UAE': 'AE',
    'AE': 'AE',
    'Саудовская Аравия': 'SA',
    'Saudi Arabia': 'SA',
    'SA': 'SA',
    'ЮАР': 'ZA',
    'South Africa': 'ZA',
    'ZA': 'ZA',
    'Мексика': 'MX',
    'Mexico': 'MX',
    'MX': 'MX',
    'Аргентина': 'AR',
    'Argentina': 'AR',
    'AR': 'AR',
    'Чили': 'CL',
    'Chile': 'CL',
    'CL': 'CL',
    'Новая Зеландия': 'NZ',
    'New Zealand': 'NZ',
    'NZ': 'NZ',
    'Ирландия': 'IE',
    'Ireland': 'IE',
    'IE': 'IE',
    'Исландия': 'IS',
    'Iceland': 'IS',
    'IS': 'IS',
    'Люксембург': 'LU',
    'Luxembourg': 'LU',
    'LU': 'LU',
    'Мальта': 'MT',
    'Malta': 'MT',
    'MT': 'MT',
    'Кипр': 'CY',
    'Cyprus': 'CY',
    'CY': 'CY',
    'Эстония': 'EE',
    'Estonia': 'EE',
    'EE': 'EE',
    'Латвия': 'LV',
    'Latvia': 'LV',
    'LV': 'LV',
    'Литва': 'LT',
    'Lithuania': 'LT',
    'LT': 'LT',
    'Словакия': 'SK',
    'Slovakia': 'SK',
    'SK': 'SK',
    'Словения': 'SI',
    'Slovenia': 'SI',
    'SI': 'SI',
    'Хорватия': 'HR',
    'Croatia': 'HR',
    'HR': 'HR',
    'Болгария': 'BG',
    'Bulgaria': 'BG',
    'BG': 'BG',
    'Румыния': 'RO',
    'Romania': 'RO',
    'RO': 'RO',
    'Украина': 'UA',
    'Ukraine': 'UA',
    'UA': 'UA',
    'Беларусь': 'BY',
    'Belarus': 'BY',
    'BY': 'BY',
    'Казахстан': 'KZ',
    'Kazakhstan': 'KZ',
    'KZ': 'KZ',
    'Узбекистан': 'UZ',
    'Uzbekistan': 'UZ',
    'UZ': 'UZ',
    'Таиланд': 'TH',
    'Thailand': 'TH',
    'TH': 'TH',
    'Вьетнам': 'VN',
    'Vietnam': 'VN',
    'VN': 'VN',
    'Малайзия': 'MY',
    'Malaysia': 'MY',
    'MY': 'MY',
    'Индонезия': 'ID',
    'Indonesia': 'ID',
    'ID': 'ID',
    'Филиппины': 'PH',
    'Philippines': 'PH',
    'PH': 'PH',
    'Египет': 'EG',
    'Egypt': 'EG',
    'EG': 'EG',
    'Марокко': 'MA',
    'Morocco': 'MA',
    'MA': 'MA',
    'Нигерия': 'NG',
    'Nigeria': 'NG',
    'NG': 'NG',
    'Кения': 'KE',
    'Kenya': 'KE',
    'KE': 'KE',
    'Гана': 'GH',
    'Ghana': 'GH',
    'GH': 'GH',
    'Танзания': 'TZ',
    'Tanzania': 'TZ',
    'TZ': 'TZ',
    'Эфиопия': 'ET',
    'Ethiopia': 'ET',
    'ET': 'ET',
    'Алжир': 'DZ',
    'Algeria': 'DZ',
    'DZ': 'DZ',
    'Тунис': 'TN',
    'Tunisia': 'TN',
    'TN': 'TN',
    'Ливия': 'LY',
    'Libya': 'LY',
    'LY': 'LY',
    'Судан': 'SD',
    'Sudan': 'SD',
    'SD': 'SD',
    'Ангола': 'AO',
    'Angola': 'AO',
    'AO': 'AO',
    'Мозамбик': 'MZ',
    'Mozambique': 'MZ',
    'MZ': 'MZ',
    'Мадагаскар': 'MG',
    'Madagascar': 'MG',
    'MG': 'MG',
    'Камерун': 'CM',
    'Cameroon': 'CM',
    'CM': 'CM',
    'Кот-д\'Ивуар': 'CI',
    'Ivory Coast': 'CI',
    'CI': 'CI',
    'Сенегал': 'SN',
    'Senegal': 'SN',
    'SN': 'SN',
    'Мали': 'ML',
    'Mali': 'ML',
    'ML': 'ML',
    'Буркина-Фасо': 'BF',
    'Burkina Faso': 'BF',
    'BF': 'BF',
    'Нигер': 'NE',
    'Niger': 'NE',
    'NE': 'NE',
    'Чад': 'TD',
    'Chad': 'TD',
    'TD': 'TD',
    'Гвинея': 'GN',
    'Guinea': 'GN',
    'GN': 'GN',
    'Сьерра-Леоне': 'SL',
    'Sierra Leone': 'SL',
    'SL': 'SL',
    'Либерия': 'LR',
    'Liberia': 'LR',
    'LR': 'LR',
    'Того': 'TG',
    'Togo': 'TG',
    'TG': 'TG',
    'Бенин': 'BJ',
    'Benin': 'BJ',
    'BJ': 'BJ',
    'Габон': 'GA',
    'Gabon': 'GA',
    'GA': 'GA',
    'Конго': 'CG',
    'Congo': 'CG',
    'CG': 'CG',
    'ДР Конго': 'CD',
    'Democratic Republic of the Congo': 'CD',
    'DR Congo': 'CD',
    'CD': 'CD',
    'ЦАР': 'CF',
    'Central African Republic': 'CF',
    'CAR': 'CF',
    'CF': 'CF',
    'Экваториальная Гвинея': 'GQ',
    'Equatorial Guinea': 'GQ',
    'GQ': 'GQ',
    'Сан-Томе и Принсипи': 'ST',
    'São Tomé and Príncipe': 'ST',
    'ST': 'ST',
    'Гвинея-Бисау': 'GW',
    'Guinea-Bissau': 'GW',
    'GW': 'GW',
    'Гамбия': 'GM',
    'Gambia': 'GM',
    'GM': 'GM',
    'Кабо-Верде': 'CV',
    'Cape Verde': 'CV',
    'CV': 'CV',
    'Мавритания': 'MR',
    'Mauritania': 'MR',
    'MR': 'MR',
    'Западная Сахара': 'EH',
    'Western Sahara': 'EH',
    'EH': 'EH',
    'Джибути': 'DJ',
    'Djibouti': 'DJ',
    'DJ': 'DJ',
    'Эритрея': 'ER',
    'Eritrea': 'ER',
    'ER': 'ER',
    'Сомали': 'SO',
    'Somalia': 'SO',
    'SO': 'SO',
    'Уганда': 'UG',
    'Uganda': 'UG',
    'UG': 'UG',
    'Руанда': 'RW',
    'Rwanda': 'RW',
    'RW': 'RW',
    'Бурунди': 'BI',
    'Burundi': 'BI',
    'BI': 'BI',
  };

  /// ISO 3166-1 alpha-2 для подписи страны из API (рус./англ. или «Страна (XX)»).
  static String? isoCountryCode(String? country) {
    if (country == null || country.isEmpty) return null;
    final normalizedCountry = country.trim();
    return _countryToCode[normalizedCountry] ??
        _countryToCode[normalizedCountry.toUpperCase()] ??
        _tryExtractCodeFromCountry(normalizedCountry);
  }

  /// Отображаемое имя страны с учётом [locale] (en → латиница, ru → кириллица при наличии в маппинге).
  static String localizedCountryName(String? country, Locale locale) {
    if (country == null || country.isEmpty) return '';
    final code = isoCountryCode(country);
    if (code == null) return country;
    final wantRussian = locale.languageCode == 'ru';
    String? cyrillic;
    String? latin;
    for (final e in _countryToCode.entries) {
      if (e.value != code) continue;
      final k = e.key;
      if (k.length == 2 && k == k.toUpperCase()) continue;
      final isCyr = RegExp(r'[А-Яа-яЁё]').hasMatch(k);
      if (isCyr) {
        cyrillic ??= k;
      } else {
        latin ??= k;
      }
    }
    if (wantRussian) return cyrillic ?? latin ?? country;
    return latin ?? cyrillic ?? country;
  }

  /// Получить эмодзи флага по названию страны
  static String getFlagEmoji(String? country) {
    if (country == null || country.isEmpty) {
      return '🌍'; // Глобус по умолчанию
    }

    final countryCode = isoCountryCode(country);

    if (countryCode == null) {
      return '🌍'; // Глобус если не найдено
    }

    // Конвертируем код в эмодзи флага
    // Эмодзи флагов используют Regional Indicator Symbols
    // Каждая буква кода (A-Z) соответствует символу U+1F1E6 (A) до U+1F1FF (Z)
    final codePoints = countryCode
        .toUpperCase()
        .split('')
        .map((char) => 0x1F1E6 + (char.codeUnitAt(0) - 0x41))
        .toList();

    return String.fromCharCodes(codePoints);
  }

  /// Попытка извлечь код из названия страны (например, "RU" из "Россия (RU)")
  static String? _tryExtractCodeFromCountry(String country) {
    // Ищем паттерн типа "Россия (RU)" или "Russia (RU)"
    final regex = RegExp(r'\(([A-Z]{2})\)');
    final match = regex.firstMatch(country);
    if (match != null) {
      return match.group(1);
    }
    
    // Если название уже является кодом (2 заглавные буквы)
    if (country.length == 2 && country == country.toUpperCase()) {
      return country;
    }
    
    return null;
  }
}

