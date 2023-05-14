// C++ program to generate short url from integer id and
// integer id back from short url.
#include "utils.h"
#include <algorithm>
#include <fstream>
#include <iostream>
#include <omp.h>
#include <string>
#include <unordered_map>
#include <vector>

using namespace std;

unordered_map<string, string> url_memcached;

#define shortURL_API_RATIO 0

string sh_ortURL(string longURL) {
  long unsigned ID = shortURLtoID(longURL);
  string shortURL = HOSTNAME + idToShortURL(ID);

  // TO DO: save to the memcached or DB
  // save (ID, longURL, shortURL)

  url_memcached.insert(make_pair(shortURL, longURL));

  return shortURL;
}

string __attribute__((noinline)) getLongURL(string shortURL) {
  // TO DO: get from the memcached or DB
  // get (shortURL)

  std::unordered_map<string, string>::const_iterator got =
      url_memcached.find(shortURL);

  if (got == url_memcached.end())
    std::cout << "ERROR: not found";
  else
    return got->second;
	return NULL; 
}

// Driver program to test above function
int main(int argc, char *argv[]) {
  if (argc < 2) {
    printf("You must provide the number of lines\n");
    exit(0);
  }

  srand(1);
  int num_lines = 0;
  int lines = 0;

  num_lines = atoi(argv[1]);

  fstream urlfile;
  vector<string> previous_url;
  std::vector<string> all_req;
  url_memcached.rehash(10000);
  urlfile.open("keylist.list", ios::in);
  if (urlfile.is_open()) {
    string tp;
    while (getline(urlfile, tp) && lines < num_lines) {
    all_req.push_back(tp);

      lines++;
    }
    urlfile.close();
  }

  for (size_t i = 0; i < 20; i++) {
    cout << "new shortURL event" << endl;

    string _shorturl = sh_ortURL(all_req[i]);
    cout << _shorturl << endl << endl;
    previous_url.push_back(_shorturl);
  }
#pragma omp parallel for
  for (size_t i = 0; i < all_req.size(); i++) {
    /* code */
    // string &tp = all_req[i];

    int index = rand() % previous_url.size();
    cout << "new getLongURL event" << endl;
    string _longurl = getLongURL(previous_url[index]);
    cout << _longurl << endl << endl;
  }
  return 0;
}