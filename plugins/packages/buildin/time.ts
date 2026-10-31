/* METADATA
{
  name: time

  display_name: {
    zh: "时间"
    en: "Time"
  }
  description: {
    zh: "提供时间相关功能。实际上，激活本包的同时已经能够获取时间了。"
    en: "Provides time-related utilities. In practice, current time is already available once this package is enabled."
  }
  enabledByDefault: true
  category: "Utility"
  tools: [
    {
      name: get_time
      description: {
        zh: "获取当前时间。当使用此包时，AI已经自动获取了当前的时间信息。"
        en: "Get the current time. When using this package, the AI may already have the current time context."
      }
      parameters: []
    },
    {
      name: format_time
      description: {
        zh: "格式化时间。提供各种时间格式化选项。"
        en: "Format time. Provides various time formatting options."
      }
      parameters: [
          {
            name: time
            type: integer
            required: false
            description: {
              zh: "要格式化的 Unix 时间戳（毫秒）。缺省为当前时间。"
              en: "Unix timestamp in milliseconds to format. Defaults to now."
            }
          },
          {
            name: pattern
            type: string
            required: false
            description: {
              zh: "输出模式。可选 24h、12h、date、iso，缺省为 24h。"
              en: "Output pattern. One of 24h, 12h, date, iso. Defaults to 24h."
            }
          }
        ]
    }
  ]
}*/

const timePackage = (function () {
  async function get_time(): Promise<any> {
    const now = new Date();

    return {
      timestamp: now.getTime(),
      iso: now.toISOString(),
      local: now.toLocaleString(),
      date: {
        year: now.getFullYear(),
        month: now.getMonth() + 1,
        day: now.getDate(),
        weekday: now.toLocaleDateString(undefined, { weekday: 'long' })
      },
      time: {
        hours: now.getHours(),
        minutes: now.getMinutes(),
        seconds: now.getSeconds()
      }
    };
  }

  async function format_time(params: any): Promise<any> {
    const args = params && typeof params === 'object' ? params : {};
    const now = args.time != null ? new Date(Number(args.time)) : new Date();
    const pattern = (args.pattern != null ? String(args.pattern) : '24h').toLowerCase();

    const pad = (n: number) => n.toString().padStart(2, '0');

    const hours = now.getHours();
    const minutes = now.getMinutes();
    const seconds = now.getSeconds();

    const time24h = `${pad(hours)}:${pad(minutes)}:${pad(seconds)}`;

    const suffix = hours >= 12 ? 'PM' : 'AM';
    const hour12 = hours % 12 === 0 ? 12 : hours % 12;
    const time12h = `${pad(hour12)}:${pad(minutes)}:${pad(seconds)} ${suffix}`;

    const iso = now.toISOString();
    const date = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
    const ts = now.getTime();

    if (pattern === '12h') return { pattern: '12h', value: time12h, timestamp: ts };
    if (pattern === 'date') return { pattern: 'date', value: date, timestamp: ts };
    if (pattern === 'iso') return { pattern: 'iso', value: iso, timestamp: ts };
    return { pattern: '24h', value: time24h, timestamp: ts };
  }

  return {
    get_time,
    format_time
  };
})();

// 逐个导出
exports.get_time = timePackage.get_time;
exports.format_time = timePackage.format_time;