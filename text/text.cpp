
#include <algorithm>
#include <chrono>
#include <fstream>
#include <future>
#include <iostream>
#include <mutex>
#include <omp.h>
#include <regex>
#include <signal.h>
#include <sstream>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <string_view>
#include <unistd.h>
#include <vector>

using namespace std;

#define HOSTNAME "http://short-url/"

// Function to generate a short url from integer ID
string idToShortURL(long unsigned n) {
  // Map to store 62 possible characters
  char map[] = "abcdefghijklmnopqrstuvwxyzABCDEF"
               "GHIJKLMNOPQRSTUVWXYZ0123456789";

  string shorturl;

  // Convert given integer id to a base 62 number
  while (n) {
    // use above map to store actual character
    // in short url
    shorturl.push_back(map[n % 62]);
    n = n / 62;
  }

  // Reverse shortURL to complete base conversion
  reverse(shorturl.begin(), shorturl.end());

  return shorturl;
}

// Function to get integer ID back from a short url
long unsigned shortURLtoID(string shortURL) {
  long unsigned id = 0; // initialize result

  // A simple base conversion logic
  for (int i = 0; i < shortURL.length(); i++) {
    if ('a' <= shortURL[i] && shortURL[i] <= 'z')
      id = id * 62 + shortURL[i] - 'a';
    if ('A' <= shortURL[i] && shortURL[i] <= 'Z')
      id = id * 62 + shortURL[i] - 'A' + 26;
    if ('0' <= shortURL[i] && shortURL[i] <= '9')
      id = id * 62 + shortURL[i] - '0' + 52;
  }
  return id;
}

string shortURL(string longURL) {
  long unsigned ID = shortURLtoID(longURL);
  string shortURL = HOSTNAME + idToShortURL(ID);

  // cout<<shortURL<<endl;

  return shortURL;
  // TO DO: save to the memcached or DB
  // save (ID, longURL, shortURL)
}

std::vector<std::string_view> matching(std::string_view &input,
                                       std::regex &re) {
  std::vector<std::string_view> result;
  std::match_results<std::string_view::const_iterator> match;

  if (std::regex_match(input.cbegin(), input.cend(), match, re)) {
    for (size_t i = 1; i < match.size(); i++) {
      const char *first = match[i].first;
      const char *last = match[i].second;
      result.push_back({first, static_cast<std::size_t>(last - first)});
    }
  }

  return result;
}

// int findCharcter( string &str,char c, int start){

//   for (size_t i = start; i < str.length(); i++)
//   {
//     if(str[i]== c) return i;

//   }

//   return -1;
// }
string processText(int64_t req_id, const std::string &text) {
  // check user mentioned
  std::vector<std::string> user_mentions;
  // std::smatch m;
  // std::regex e("@[a-zA-Z0-9-_]+");
  auto &s = text;
  size_t idx = 0;
  while (true) {

    idx = s.find('@', idx);

    if (idx == std::string::npos)
      break;
    // cout<<"dddddddd\n"<<s.substr(idx+1, s.find(' ',idx+1)-idx-1) <<endl;
    // auto user_mention = m.str();
    // user_mention = user_mention.substr(1, user_mention.length());
    // if(std::regex_search(s, m, e))
    user_mentions.emplace_back(
        s.substr(idx + 1, s.find(' ', idx + 1) - idx - 1));
    idx++;
  }

  // cout<<"---" << idx <<endl;
  // TO DO: add user mentioned in the database
  for (unsigned i = 0; i < user_mentions.size(); i++)
    cout << user_mentions[i] << endl;

  // check urls
  idx = 0;
  size_t new_idx = 0;
  std::vector<std::string> urls;
  // e = "(http://|https://)([a-zA-Z0-9_!~*'().&=+$%-]+)";
  auto &ss = text;
  while (true) {
    new_idx = ss.find("http://", idx);

    if (new_idx == std::string::npos) {

      new_idx = ss.find("https://", idx);
    }
    if (new_idx == std::string::npos) {

      break;
    }
    idx = new_idx;

    size_t end_of_url = ss.find(',', idx);
    //  cout<<"dddddddd\n" << end_of_url<<endl;
    // auto url = m.str();
    urls.emplace_back(ss.substr(idx, end_of_url - idx - 1));
    idx++;
  }

  std::vector<std::string> shortened_urls;
  for (unsigned i = 0; i < urls.size(); i++) {
    // cout<< urls[i] <<endl;
    // shortURL
    shortened_urls.push_back((urls[i]));
  }

  std::string updated_text;
  if (!urls.empty()) {
    auto &st = text;
    idx = 0;
    new_idx = 0;
    size_t end_of_url = 0;
    int m = 0;
    while (true) {
      new_idx = st.find("http://", idx);

      if (new_idx == std::string::npos) {

        new_idx = st.find("https://", idx);
      }
      if (new_idx == std::string::npos) {

        break;
      }

      end_of_url = st.find(',', new_idx);
      // cout<<st.substr(idx,new_idx-idx) <<endl;
      updated_text += st.substr(idx, new_idx - idx) + shortened_urls[m];
      idx = end_of_url;
      // idx++;
      m++;
    }
  } else {
    updated_text = text;
  }

  return updated_text;
}
std::string gen_random_string(const int len) {
  static const char alphanum[] = "0123456789"
                                 "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
                                 "abcdefghijklmnopqrstuvwxyz";
  std::string tmp_s;
  tmp_s.reserve(len);

  for (int i = 0; i < len; ++i) {
    tmp_s += alphanum[rand() % (sizeof(alphanum) - 1)];
  }

  return tmp_s;
}

int main(int argc, char *argv[]) {

  if (argc < 3) {
    printf("You must provide the number of lines and csv file\n");
    exit(0);
  }

  int num_lines = 0;
  int lines = 0;
  fstream postfile;

  std::string fstream(argv[1]);
  num_lines = atoi(argv[2]);

  postfile.open(argv[1], ios::in);
  std::vector<string> all_req;
  if (postfile.is_open()) {
    string tp;
    cout << "post id text: " << lines << endl;

    while (getline(postfile, tp) && lines < num_lines) {
      // if (tp == "")
      //   continue;
      // stringstream ss(tp);
      // vector<string> v;
      // while (ss.good()) {
      //   string substr;
      //   getline(ss, substr, ',');
      //   v.push_back(substr);
      // }
      string link = gen_random_string(20);
      tp = gen_random_string(100) + ", http://" + link;
      all_req.push_back(tp);

      // cout << "post id text: " << lines << endl;
      // cout << "original text: " << tp << endl;
      lines++;
    }
    postfile.close();
  }

// #pragma omp parallel for
  for (size_t i = 0; i < all_req.size(); i++) {
    /* code */
    string &tp = all_req[i];

    cout << "processed text: " << processText(i, tp) << endl << endl;
  }

  return 0;
}
