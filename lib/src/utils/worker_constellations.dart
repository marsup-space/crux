/// Stable IAU constellation identities for automatically named Workers.
///
/// Crux is excluded because it is the application name, leaving the other 87
/// official constellations available. Persist the stable [id], then render a
/// locale-specific display name at the UI boundary.
library;

class WorkerConstellation {
  final String id;
  final String englishName;
  final String chineseName;

  const WorkerConstellation(this.id, this.englishName, this.chineseName);
}

const List<WorkerConstellation> kWorkerConstellations = [
  WorkerConstellation('andromeda', 'Andromeda', '仙女座'),
  WorkerConstellation('antlia', 'Antlia', '唧筒座'),
  WorkerConstellation('apus', 'Apus', '天燕座'),
  WorkerConstellation('aquarius', 'Aquarius', '宝瓶座'),
  WorkerConstellation('aquila', 'Aquila', '天鹰座'),
  WorkerConstellation('ara', 'Ara', '天坛座'),
  WorkerConstellation('aries', 'Aries', '白羊座'),
  WorkerConstellation('auriga', 'Auriga', '御夫座'),
  WorkerConstellation('bootes', 'Boötes', '牧夫座'),
  WorkerConstellation('caelum', 'Caelum', '雕具座'),
  WorkerConstellation('camelopardalis', 'Camelopardalis', '鹿豹座'),
  WorkerConstellation('cancer', 'Cancer', '巨蟹座'),
  WorkerConstellation('canes-venatici', 'Canes Venatici', '猎犬座'),
  WorkerConstellation('canis-major', 'Canis Major', '大犬座'),
  WorkerConstellation('canis-minor', 'Canis Minor', '小犬座'),
  WorkerConstellation('capricornus', 'Capricornus', '摩羯座'),
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
  WorkerConstellation('gemini', 'Gemini', '双子座'),
  WorkerConstellation('grus', 'Grus', '天鹤座'),
  WorkerConstellation('hercules', 'Hercules', '武仙座'),
  WorkerConstellation('horologium', 'Horologium', '时钟座'),
  WorkerConstellation('hydra', 'Hydra', '长蛇座'),
  WorkerConstellation('hydrus', 'Hydrus', '水蛇座'),
  WorkerConstellation('indus', 'Indus', '印第安座'),
  WorkerConstellation('lacerta', 'Lacerta', '蝎虎座'),
  WorkerConstellation('leo', 'Leo', '狮子座'),
  WorkerConstellation('leo-minor', 'Leo Minor', '小狮座'),
  WorkerConstellation('lepus', 'Lepus', '天兔座'),
  WorkerConstellation('libra', 'Libra', '天秤座'),
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
  WorkerConstellation('pisces', 'Pisces', '双鱼座'),
  WorkerConstellation('piscis-austrinus', 'Piscis Austrinus', '南鱼座'),
  WorkerConstellation('puppis', 'Puppis', '船尾座'),
  WorkerConstellation('pyxis', 'Pyxis', '罗盘座'),
  WorkerConstellation('reticulum', 'Reticulum', '网罟座'),
  WorkerConstellation('sagitta', 'Sagitta', '天箭座'),
  WorkerConstellation('sagittarius', 'Sagittarius', '人马座'),
  WorkerConstellation('scorpius', 'Scorpius', '天蝎座'),
  WorkerConstellation('sculptor', 'Sculptor', '玉夫座'),
  WorkerConstellation('scutum', 'Scutum', '盾牌座'),
  WorkerConstellation('serpens', 'Serpens', '巨蛇座'),
  WorkerConstellation('sextans', 'Sextans', '六分仪座'),
  WorkerConstellation('taurus', 'Taurus', '金牛座'),
  WorkerConstellation('telescopium', 'Telescopium', '望远镜座'),
  WorkerConstellation('triangulum', 'Triangulum', '三角座'),
  WorkerConstellation('triangulum-australe', 'Triangulum Australe', '南三角座'),
  WorkerConstellation('tucana', 'Tucana', '杜鹃座'),
  WorkerConstellation('ursa-major', 'Ursa Major', '大熊座'),
  WorkerConstellation('ursa-minor', 'Ursa Minor', '小熊座'),
  WorkerConstellation('vela', 'Vela', '船帆座'),
  WorkerConstellation('virgo', 'Virgo', '室女座'),
  WorkerConstellation('volans', 'Volans', '飞鱼座'),
  WorkerConstellation('vulpecula', 'Vulpecula', '狐狸座'),
];

/// Resolves both new stable ids and legacy English display names.
WorkerConstellation? constellationForPersistedName(String value) {
  final normalized = value.trim().toLowerCase();
  for (final constellation in kWorkerConstellations) {
    if (normalized == constellation.id ||
        normalized == constellation.englishName.toLowerCase()) {
      return constellation;
    }
  }
  return null;
}

/// Converts a legacy English display name to its stable persisted id.
String normalizeWorkerConstellationId(String persistedName) =>
    constellationForPersistedName(persistedName)?.id ?? persistedName;
