/// Stable IAU constellation identities for automatically named agents.
///
/// Two pools: the 12 zodiac constellations name **experts**; the remaining
/// 75 (Crux itself excluded — it is the application name) name **workers**.
/// Persist the stable [id], then render a locale-specific display name at
/// the UI boundary. When a pool is exhausted, ids get a numeric suffix
/// (`orion-2`); the suffix lives in the persisted name, not here.
library;

class WorkerConstellation {
  final String id;
  final String englishName;
  final String chineseName;

  const WorkerConstellation(this.id, this.englishName, this.chineseName);
}

/// The 12 zodiac constellations — the expert name pool.
///
/// Chinese names use the popular astrology wording (处女/射手/水瓶) rather
/// than the IAU astronomy wording (室女/人马/宝瓶): users recognise these
/// at a glance, which matters more in a chat product than catalog purity.
const List<WorkerConstellation> kExpertConstellations = [
  WorkerConstellation('aries', 'Aries', '白羊座'),
  WorkerConstellation('taurus', 'Taurus', '金牛座'),
  WorkerConstellation('gemini', 'Gemini', '双子座'),
  WorkerConstellation('cancer', 'Cancer', '巨蟹座'),
  WorkerConstellation('leo', 'Leo', '狮子座'),
  WorkerConstellation('virgo', 'Virgo', '处女座'),
  WorkerConstellation('libra', 'Libra', '天秤座'),
  WorkerConstellation('scorpius', 'Scorpius', '天蝎座'),
  WorkerConstellation('sagittarius', 'Sagittarius', '射手座'),
  WorkerConstellation('capricornus', 'Capricornus', '摩羯座'),
  WorkerConstellation('aquarius', 'Aquarius', '水瓶座'),
  WorkerConstellation('pisces', 'Pisces', '双鱼座'),
];

/// The non-zodiac constellations — the worker name pool.
const List<WorkerConstellation> kWorkerConstellations = [
  WorkerConstellation('andromeda', 'Andromeda', '仙女座'),
  WorkerConstellation('antlia', 'Antlia', '唧筒座'),
  WorkerConstellation('apus', 'Apus', '天燕座'),
  WorkerConstellation('aquila', 'Aquila', '天鹰座'),
  WorkerConstellation('ara', 'Ara', '天坛座'),
  WorkerConstellation('auriga', 'Auriga', '御夫座'),
  WorkerConstellation('bootes', 'Boötes', '牧夫座'),
  WorkerConstellation('caelum', 'Caelum', '雕具座'),
  WorkerConstellation('camelopardalis', 'Camelopardalis', '鹿豹座'),
  WorkerConstellation('canes-venatici', 'Canes Venatici', '猎犬座'),
  WorkerConstellation('canis-major', 'Canis Major', '大犬座'),
  WorkerConstellation('canis-minor', 'Canis Minor', '小犬座'),
  WorkerConstellation('carina', 'Carina', '船底座'),
  WorkerConstellation('cassiopeia', 'Cassiopeia', '仙后座'),
  WorkerConstellation('centaurus', 'Centaurus', '半人马座'),
  WorkerConstellation('cepheus', 'Cepheus', '仙王座'),
  WorkerConstellation('cetus', 'Cetus', '鲸鱼座'),
  WorkerConstellation('chamaeleon', 'Chamaeleon', '堰蜒座'),
  WorkerConstellation('circinus', 'Circinus', '圆规座'),
  WorkerConstellation('columba', 'Columba', '天鸽座'),
  WorkerConstellation('coma-berenices', 'Coma Berenices', '后发座'),
  WorkerConstellation('corona-australis', 'Corona Australis', '南冕座'),
  WorkerConstellation('corona-borealis', 'Corona Borealis', '北冕座'),
  WorkerConstellation('corvus', 'Corvus', '乌鸦座'),
  WorkerConstellation('crater', 'Crater', '巨爵座'),
  WorkerConstellation('cygnus', 'Cygnus', '天鹅座'),
  WorkerConstellation('delphinus', 'Delphinus', '海豚座'),
  WorkerConstellation('dorado', 'Dorado', '剑鱼座'),
  WorkerConstellation('draco', 'Draco', '天龙座'),
  WorkerConstellation('equuleus', 'Equuleus', '小马座'),
  WorkerConstellation('eridanus', 'Eridanus', '波江座'),
  WorkerConstellation('fornax', 'Fornax', '天炉座'),
  WorkerConstellation('grus', 'Grus', '天鹤座'),
  WorkerConstellation('hercules', 'Hercules', '武仙座'),
  WorkerConstellation('horologium', 'Horologium', '时钟座'),
  WorkerConstellation('hydra', 'Hydra', '长蛇座'),
  WorkerConstellation('hydrus', 'Hydrus', '水蛇座'),
  WorkerConstellation('indus', 'Indus', '印第安座'),
  WorkerConstellation('lacerta', 'Lacerta', '蝎虎座'),
  WorkerConstellation('leo-minor', 'Leo Minor', '小狮座'),
  WorkerConstellation('lepus', 'Lepus', '天兔座'),
  WorkerConstellation('lupus', 'Lupus', '豺狼座'),
  WorkerConstellation('lynx', 'Lynx', '天猫座'),
  WorkerConstellation('lyra', 'Lyra', '天琴座'),
  WorkerConstellation('mensa', 'Mensa', '山案座'),
  WorkerConstellation('microscopium', 'Microscopium', '显微镜座'),
  WorkerConstellation('monoceros', 'Monoceros', '麒麟座'),
  WorkerConstellation('musca', 'Musca', '苍蝇座'),
  WorkerConstellation('norma', 'Norma', '矩尺座'),
  WorkerConstellation('octans', 'Octans', '南极座'),
  WorkerConstellation('ophiuchus', 'Ophiuchus', '蛇夫座'),
  WorkerConstellation('orion', 'Orion', '猎户座'),
  WorkerConstellation('pavo', 'Pavo', '孔雀座'),
  WorkerConstellation('pegasus', 'Pegasus', '飞马座'),
  WorkerConstellation('perseus', 'Perseus', '英仙座'),
  WorkerConstellation('phoenix', 'Phoenix', '凤凰座'),
  WorkerConstellation('pictor', 'Pictor', '绘架座'),
  WorkerConstellation('piscis-austrinus', 'Piscis Austrinus', '南鱼座'),
  WorkerConstellation('puppis', 'Puppis', '船尾座'),
  WorkerConstellation('pyxis', 'Pyxis', '罗盘座'),
  WorkerConstellation('reticulum', 'Reticulum', '网罟座'),
  WorkerConstellation('sagitta', 'Sagitta', '天箭座'),
  WorkerConstellation('sculptor', 'Sculptor', '玉夫座'),
  WorkerConstellation('scutum', 'Scutum', '盾牌座'),
  WorkerConstellation('serpens', 'Serpens', '巨蛇座'),
  WorkerConstellation('sextans', 'Sextans', '六分仪座'),
  WorkerConstellation('telescopium', 'Telescopium', '望远镜座'),
  WorkerConstellation('triangulum', 'Triangulum', '三角座'),
  WorkerConstellation('triangulum-australe', 'Triangulum Australe', '南三角座'),
  WorkerConstellation('tucana', 'Tucana', '杜鹃座'),
  WorkerConstellation('ursa-major', 'Ursa Major', '大熊座'),
  WorkerConstellation('ursa-minor', 'Ursa Minor', '小熊座'),
  WorkerConstellation('vela', 'Vela', '船帆座'),
  WorkerConstellation('volans', 'Volans', '飞鱼座'),
  WorkerConstellation('vulpecula', 'Vulpecula', '狐狸座'),
];

/// Resolves ids (and legacy English display names) from either pool.
WorkerConstellation? constellationForPersistedName(String value) {
  final normalized = value.trim().toLowerCase();
  for (final constellation in kExpertConstellations) {
    if (normalized == constellation.id ||
        normalized == constellation.englishName.toLowerCase()) {
      return constellation;
    }
  }
  for (final constellation in kWorkerConstellations) {
    if (normalized == constellation.id ||
        normalized == constellation.englishName.toLowerCase()) {
      return constellation;
    }
  }
  return null;
}

/// The naming pool for one agent role.
enum ConstellationPool { worker, expert }

/// Lists the allocation order for [pool] — zodiac for experts, the rest
/// for workers. Allocators walk this list and take the first name not yet
/// persisted, appending `-2`, `-3`, … once the pool cycles.
List<WorkerConstellation> constellationPoolFor(ConstellationPool pool) =>
    switch (pool) {
      ConstellationPool.worker => kWorkerConstellations,
      ConstellationPool.expert => kExpertConstellations,
    };

/// Converts a legacy English display name to its stable persisted id.
String normalizeWorkerConstellationId(String persistedName) =>
    constellationForPersistedName(persistedName)?.id ?? persistedName;
